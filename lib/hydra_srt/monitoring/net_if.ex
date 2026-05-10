defmodule HydraSrt.Monitoring.NetIf do
  @moduledoc false

  alias HydraSrt.Monitoring.NetIfMetrics

  @sysfs_stats_base "/sys/class/net"
  @linux_proc_net_dev "/proc/net/dev"

  @type iface_counters :: %{optional(atom()) => non_neg_integer()}
  @type snapshot :: %{optional(binary()) => iface_counters()}

  @spec snapshot() :: snapshot()
  def snapshot do
    case :os.type() do
      {:unix, :linux} -> linux_snapshot()
      {:unix, :darwin} -> bsd_snapshot()
      {:unix, :freebsd} -> bsd_snapshot()
      _ -> %{}
    end
  end

  @spec rates(snapshot(), snapshot(), non_neg_integer()) :: snapshot()
  def rates(prev_snapshot, curr_snapshot, delta_ms)
      when is_map(prev_snapshot) and is_map(curr_snapshot) and is_integer(delta_ms) do
    if delta_ms <= 0 do
      %{}
    else
      seconds = delta_ms / 1000.0

      curr_snapshot
      |> Enum.reduce(%{}, fn {iface, curr}, acc ->
        prev = Map.get(prev_snapshot, iface, %{})

        rates_for_iface =
          NetIfMetrics.counter_keys()
          |> Enum.reduce(%{}, fn key, iface_acc ->
            with curr_v when is_integer(curr_v) <- curr[key],
                 prev_v when is_integer(prev_v) <- prev[key],
                 true <- curr_v >= prev_v do
              Map.put(iface_acc, key, (curr_v - prev_v) / seconds)
            else
              _ -> iface_acc
            end
          end)

        if map_size(rates_for_iface) == 0 do
          acc
        else
          Map.put(acc, iface, rates_for_iface)
        end
      end)
    end
  end

  @spec linux_snapshot() :: snapshot()
  def linux_snapshot do
    case read_linux_sysfs_stats() do
      %{} = stats when map_size(stats) > 0 ->
        stats

      _ ->
        case File.read(@linux_proc_net_dev) do
          {:ok, contents} -> parse_proc_net_dev(contents)
          _ -> %{}
        end
    end
  end

  @spec bsd_snapshot() :: snapshot()
  def bsd_snapshot do
    args =
      case :os.type() do
        {:unix, :darwin} -> ["-i", "-b", "-n", "-W"]
        _ -> ["-i", "-b", "-n"]
      end

    case System.cmd("netstat", args, stderr_to_stdout: true) do
      {output, 0} -> parse_netstat_ibn(output)
      _ -> %{}
    end
  end

  @spec parse_proc_net_dev(binary()) :: snapshot()
  def parse_proc_net_dev(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.drop(2)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [iface_raw, counters_raw] ->
          iface = iface_raw |> String.trim()
          counters = counters_raw |> String.split(~r/\s+/, trim: true)

          case parse_linux_proc_counters(counters) do
            nil -> acc
            parsed -> Map.put(acc, iface, parsed)
          end

        _ ->
          acc
      end
    end)
  end

  @spec parse_netstat_ibn(binary()) :: snapshot()
  def parse_netstat_ibn(contents) when is_binary(contents) do
    lines = String.split(contents, "\n", trim: true)

    with {header, data_lines} <- split_header_and_data(lines),
         {_indexes, needed_present?} <- build_netstat_indexes(header),
         true <- needed_present? do
      parse_netstat_rows(data_lines, header)
    else
      _ -> %{}
    end
  end

  defp read_linux_sysfs_stats do
    case File.ls(@sysfs_stats_base) do
      {:ok, ifaces} ->
        ifaces
        |> Enum.reduce(%{}, fn iface, acc ->
          case read_linux_iface_stats(iface) do
            nil -> acc
            stats -> Map.put(acc, iface, stats)
          end
        end)

      _ ->
        %{}
    end
  end

  defp read_linux_iface_stats(iface) do
    stats_dir = Path.join([@sysfs_stats_base, iface, "statistics"])

    NetIfMetrics.counter_keys()
    |> Enum.reduce(%{}, fn key, acc ->
      path = Path.join(stats_dir, Atom.to_string(key))

      case File.read(path) do
        {:ok, value} ->
          case Integer.parse(String.trim(value)) do
            {parsed, ""} -> Map.put(acc, key, parsed)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
    |> case do
      stats when map_size(stats) == 0 -> nil
      stats -> stats
    end
  end

  defp parse_linux_proc_counters(counters) when length(counters) >= 12 do
    with {:ok, rx_bytes} <- parse_int_at(counters, 0),
         {:ok, rx_packets} <- parse_int_at(counters, 1),
         {:ok, rx_errors} <- parse_int_at(counters, 2),
         {:ok, rx_dropped} <- parse_int_at(counters, 3),
         {:ok, tx_bytes} <- parse_int_at(counters, 8),
         {:ok, tx_packets} <- parse_int_at(counters, 9),
         {:ok, tx_errors} <- parse_int_at(counters, 10),
         {:ok, tx_dropped} <- parse_int_at(counters, 11) do
      %{
        rx_bytes: rx_bytes,
        tx_bytes: tx_bytes,
        rx_packets: rx_packets,
        tx_packets: tx_packets,
        rx_errors: rx_errors,
        tx_errors: tx_errors,
        rx_dropped: rx_dropped,
        tx_dropped: tx_dropped
      }
    else
      _ -> nil
    end
  end

  defp parse_linux_proc_counters(_), do: nil

  defp split_header_and_data(lines) do
    case Enum.split_while(lines, fn line -> not String.starts_with?(String.trim(line), "Name") end) do
      {_before, []} ->
        {[], []}

      {_before, [header | rest]} ->
        {String.split(header, ~r/\s+/, trim: true), rest}
    end
  end

  defp build_netstat_indexes(header_tokens) do
    indexes =
      header_tokens
      |> Enum.with_index()
      |> Enum.into(%{}, fn {name, idx} -> {String.downcase(name), idx} end)

    required = ["name", "ipkts", "opkts", "ierrs", "oerrs", "ibytes", "obytes"]
    {indexes, Enum.all?(required, &Map.has_key?(indexes, &1))}
  end

  defp parse_netstat_rows(lines, header_tokens) do
    {indexes, _} = build_netstat_indexes(header_tokens)

    lines
    |> Enum.reduce(%{}, fn line, acc ->
      tokens = String.split(String.trim(line), ~r/\s+/, trim: true)

      with {:ok, iface} <- token_at(tokens, indexes["name"]),
           true <- String.trim(iface) != "",
           true <- not String.contains?(iface, "*"),
           :ok <- maybe_skip_non_link_row(tokens, indexes) do
        parsed = %{
          rx_bytes: parse_netstat_int(tokens, indexes["ibytes"]),
          tx_bytes: parse_netstat_int(tokens, indexes["obytes"]),
          rx_packets: parse_netstat_int(tokens, indexes["ipkts"]),
          tx_packets: parse_netstat_int(tokens, indexes["opkts"]),
          rx_errors: parse_netstat_int(tokens, indexes["ierrs"]),
          tx_errors: parse_netstat_int(tokens, indexes["oerrs"])
        }

        parsed =
          parsed
          |> maybe_put_drop(:rx_dropped, tokens, indexes, ["idrop", "iqdrops"])
          |> maybe_put_drop(:tx_dropped, tokens, indexes, ["odrop", "oqdrops", "drops"])

        merge_netstat_rows(acc, iface, parsed)
      else
        _ -> acc
      end
    end)
  end

  defp maybe_skip_non_link_row(tokens, indexes) do
    case token_at(tokens, Map.get(indexes, "network")) do
      {:ok, network} ->
        # For BSD we only want the link-level row to avoid duplicates per alias IP.
        if String.starts_with?(network, "<Link#") or network == "link#" do
          :ok
        else
          :skip
        end

      _ ->
        :ok
    end
  end

  defp maybe_put_drop(map, key, tokens, indexes, names) do
    idx =
      Enum.find_value(names, fn name ->
        Map.get(indexes, String.downcase(name))
      end)

    if is_integer(idx) do
      case parse_netstat_int(tokens, idx) do
        value when is_integer(value) -> Map.put(map, key, value)
        _ -> map
      end
    else
      map
    end
  end

  defp merge_netstat_rows(acc, iface, parsed) do
    existing = Map.get(acc, iface, %{})

    merged =
      Map.merge(existing, parsed, fn _k, a, b ->
        max(a || 0, b || 0)
      end)

    Map.put(acc, iface, merged)
  end

  defp parse_netstat_int(tokens, idx) when is_integer(idx) do
    case token_at(tokens, idx) do
      {:ok, "-"} -> nil
      {:ok, value} -> parse_int_loose(value)
      _ -> nil
    end
  end

  defp parse_int_loose(value) when is_binary(value) do
    value
    |> String.replace(",", "")
    |> Integer.parse()
    |> case do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int_at(values, idx) do
    with {:ok, value} <- token_at(values, idx),
         {parsed, ""} <- Integer.parse(value) do
      {:ok, parsed}
    else
      _ -> :error
    end
  end

  defp token_at(tokens, idx) when is_list(tokens) and is_integer(idx) and idx >= 0 do
    case Enum.at(tokens, idx) do
      nil -> :error
      token -> {:ok, token}
    end
  end
end
