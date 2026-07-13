defmodule HydraSrt.Monitoring.OsMon do
  @moduledoc false

  require Logger

  @spec ram_usage() :: float()
  def ram_usage do
    :memsup.get_system_memory_data()
    |> ram_usage_from_memory_data()
  end

  @spec cpu_la() :: %{avg1: float(), avg5: float(), avg15: float()}
  def cpu_la do
    %{
      avg1: :cpu_sup.avg1() / 256,
      avg5: :cpu_sup.avg5() / 256,
      avg15: :cpu_sup.avg15() / 256
    }
  end

  @spec cpu_util() :: float() | {:error, term()}
  def cpu_util do
    :cpu_sup.util()
  end

  @spec swap_usage() :: float() | nil
  def swap_usage do
    mem = :memsup.get_system_memory_data()

    with total_swap when is_integer(total_swap) and total_swap > 0 <-
           Keyword.get(mem, :total_swap),
         free_swap when is_integer(free_swap) <- Keyword.get(mem, :free_swap) do
      swap_usage_percent(total_swap, free_swap)
    else
      _ -> os_swap_usage_fallback()
    end
  end

  @doc """
  Get all system stats in a single call
  """
  @spec get_all_stats() :: %{
          cpu: float() | {:error, term()},
          ram: float(),
          swap: float() | nil,
          cpu_la: %{avg1: float(), avg5: float(), avg15: float()},
          storage: map(),
          databases: map()
        }
  def get_all_stats do
    %{
      cpu: cpu_util(),
      ram: ram_usage(),
      swap: swap_usage(),
      cpu_la: cpu_la(),
      storage: storage(),
      databases: databases()
    }
  end

  @spec storage() :: map()
  def storage do
    case :os.type() do
      {:unix, :darwin} -> darwin_storage()
      _ -> disksup_storage()
    end
  rescue
    error ->
      Logger.debug("Storage metrics collection failed: #{inspect(error)}")
      %{}
  catch
    kind, reason ->
      Logger.debug("Storage metrics collection failed: #{inspect({kind, reason})}")
      %{}
  end

  @spec disksup_storage() :: map()
  def disksup_storage do
    :disksup.get_disk_data()
    |> storage_from_disk_data()
  end

  @spec darwin_storage() :: map()
  def darwin_storage do
    df_storage =
      case System.cmd("df", ["-k"]) do
        {output, 0} -> storage_from_df_output(output)
        _ -> %{}
      end

    merge_darwin_storage(disksup_storage(), df_storage)
  end

  @spec merge_darwin_storage(map(), map()) :: map()
  def merge_darwin_storage(disksup_storage, df_storage)
      when is_map(disksup_storage) and is_map(df_storage) do
    Map.merge(disksup_storage, df_storage)
  end

  @spec storage_from_disk_data(list()) :: map()
  def storage_from_disk_data(disk_data) when is_list(disk_data) do
    disk_data
    |> Enum.map(&storage_entry_from_disk_tuple/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{}, fn entry -> {entry.id, entry} end)
  end

  def storage_from_disk_data(_disk_data), do: %{}

  @spec storage_from_df_output(String.t()) :: map()
  def storage_from_df_output(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&storage_entry_from_df_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{}, fn entry -> {entry.id, entry} end)
  end

  def storage_from_df_output(_output), do: %{}

  @spec storage_id(String.t()) :: String.t()
  def storage_id("/"), do: "root"

  def storage_id(mountpoint) when is_binary(mountpoint) do
    mountpoint
    |> Base.url_encode64(padding: false)
    |> case do
      "" -> "unknown"
      encoded -> encoded
    end
  end

  def storage_id(_mountpoint), do: "unknown"

  @spec databases() :: map()
  def databases do
    [
      {"metadata_database", "Metadata Database", repo_database_path()}
    ]
    |> Enum.reject(fn {_id, _name, path} -> is_nil(path) or path == "" end)
    |> Enum.map(&database_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{}, fn entry -> {entry.id, entry} end)
  end

  @spec database_id(String.t()) :: String.t()
  def database_id("metadata_database"), do: "metadata_database"
  def database_id(value) when is_binary(value), do: storage_id(value)
  def database_id(_value), do: "unknown"

  @spec ram_usage_from_memory_data(keyword()) :: float()
  def ram_usage_from_memory_data(mem) do
    total_memory = Keyword.get(mem, :total_memory)

    available_memory =
      case Keyword.get(mem, :available_memory) do
        value when is_integer(value) and value >= 0 ->
          value

        _ ->
          free = memory_value(mem, :free_memory)
          cached = memory_value(mem, :cached_memory)
          buffered = memory_value(mem, :buffered_memory)
          free + cached + buffered
      end

    cond do
      not is_integer(total_memory) or total_memory <= 0 ->
        0.0

      true ->
        usage = 100.0 - available_memory / total_memory * 100.0
        min(max(usage, 0.0), 100.0)
    end
  end

  defp memory_value(mem, key) do
    case Keyword.get(mem, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  def storage_entry_from_disk_tuple({mountpoint_raw, total_kbytes, used_percent})
      when is_integer(total_kbytes) and total_kbytes > 0 and is_number(used_percent) do
    mountpoint = mountpoint_to_string(mountpoint_raw)

    if mountpoint == "" or mountpoint == "none" do
      nil
    else
      total_bytes = total_kbytes * 1024
      normalized_used_percent = min(max(used_percent * 1.0, 0.0), 100.0)
      used_bytes = round(total_bytes * normalized_used_percent / 100.0)
      free_bytes = max(total_bytes - used_bytes, 0)

      %{
        id: storage_id(mountpoint),
        mountpoint: mountpoint,
        total_bytes: total_bytes,
        used_bytes: used_bytes,
        free_bytes: free_bytes,
        used_percent: normalized_used_percent
      }
    end
  end

  def storage_entry_from_disk_tuple(_disk_tuple), do: nil

  def storage_entry_from_df_line(line) when is_binary(line) do
    case Regex.run(~r/^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\S+\s+\S+\s+\S+\s+\S+\s+(.+)$/, line) do
      [_, filesystem, total_kbytes, used_kbytes, available_kbytes, mountpoint]
      when filesystem != "devfs" ->
        storage_entry_from_df_values(
          filesystem,
          mountpoint,
          parse_non_negative_integer(total_kbytes),
          parse_non_negative_integer(used_kbytes),
          parse_non_negative_integer(available_kbytes)
        )

      _ ->
        nil
    end
  end

  def storage_entry_from_df_line(_line), do: nil

  def storage_entry_from_df_values(
        filesystem,
        mountpoint,
        total_kbytes,
        used_kbytes,
        available_kbytes
      )
      when is_binary(filesystem) and is_binary(mountpoint) and is_integer(total_kbytes) and
             total_kbytes > 0 and is_integer(used_kbytes) and used_kbytes >= 0 and
             is_integer(available_kbytes) and available_kbytes >= 0 do
    if String.starts_with?(filesystem, "/dev/") and mountpoint != "" and mountpoint != "none" do
      used_kbytes =
        if mountpoint == "/", do: max(total_kbytes - available_kbytes, 0), else: used_kbytes

      total_bytes = total_kbytes * 1024
      used_bytes = used_kbytes * 1024
      free_bytes = available_kbytes * 1024
      used_percent = min(max(used_bytes / total_bytes * 100.0, 0.0), 100.0)

      %{
        id: storage_id(mountpoint),
        mountpoint: mountpoint,
        total_bytes: total_bytes,
        used_bytes: used_bytes,
        free_bytes: free_bytes,
        used_percent: used_percent
      }
    end
  end

  def storage_entry_from_df_values(
        _filesystem,
        _mountpoint,
        _total_kbytes,
        _used_kbytes,
        _available_kbytes
      ),
      do: nil

  def parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  def parse_non_negative_integer(_value), do: nil

  def mountpoint_to_string(value) when is_binary(value), do: value
  def mountpoint_to_string(value) when is_list(value), do: List.to_string(value)
  def mountpoint_to_string(value), do: to_string(value)

  def database_entry({id, name, path})
      when is_binary(id) and is_binary(name) and is_binary(path) do
    expanded_path = Path.expand(path)
    size_bytes = database_footprint_bytes(expanded_path)

    %{
      id: database_id(id),
      name: name,
      path: expanded_path,
      size_bytes: size_bytes
    }
  end

  def database_entry(_entry), do: nil

  @spec database_footprint_bytes(String.t()) :: non_neg_integer()
  def database_footprint_bytes(path) when is_binary(path) do
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.map(&file_size/1)
    |> Enum.sum()
  end

  def file_size(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when is_integer(size) and size >= 0 -> size
      _ -> 0
    end
  end

  def repo_database_path do
    :hydra_srt
    |> Application.get_env(HydraSrt.Repo, [])
    |> Keyword.get(:database)
  end

  defp swap_usage_percent(total_swap, free_swap)
       when is_integer(total_swap) and total_swap > 0 and is_integer(free_swap) do
    usage = 100.0 - free_swap / total_swap * 100.0
    min(max(usage, 0.0), 100.0)
  end

  defp os_swap_usage_fallback do
    case :os.type() do
      {:unix, :darwin} -> darwin_swap_usage()
      {:unix, :linux} -> linux_swap_usage()
      _ -> nil
    end
  end

  defp darwin_swap_usage do
    case System.cmd("sysctl", ["-n", "vm.swapusage"]) do
      {output, 0} ->
        parse_darwin_swap_usage(output)

      _ ->
        nil
    end
  end

  defp linux_swap_usage do
    case File.read("/proc/meminfo") do
      {:ok, contents} ->
        parse_linux_swap_usage(contents)

      _ ->
        nil
    end
  end

  @spec parse_darwin_swap_usage(String.t()) :: float() | nil
  def parse_darwin_swap_usage(output) when is_binary(output) do
    with [_, total_raw, used_raw] <-
           Regex.run(
             ~r/total\s*=\s*([0-9.]+(?:[KMGTP])?)\s+used\s*=\s*([0-9.]+(?:[KMGTP])?)/i,
             output
           ),
         total when is_integer(total) and total > 0 <- parse_size_to_bytes(total_raw),
         used when is_integer(used) and used >= 0 <- parse_size_to_bytes(used_raw) do
      usage = used / total * 100.0
      min(max(usage, 0.0), 100.0)
    else
      _ -> nil
    end
  end

  @spec parse_linux_swap_usage(String.t()) :: float() | nil
  def parse_linux_swap_usage(contents) when is_binary(contents) do
    with [_, total_kb] <- Regex.run(~r/^SwapTotal:\s+(\d+)\s+kB$/m, contents),
         [_, free_kb] <- Regex.run(~r/^SwapFree:\s+(\d+)\s+kB$/m, contents),
         {total, ""} <- Integer.parse(total_kb),
         {free, ""} <- Integer.parse(free_kb),
         true <- total > 0 do
      swap_usage_percent(total, free)
    else
      _ -> nil
    end
  end

  defp parse_size_to_bytes(raw) when is_binary(raw) do
    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)([KMGTP])?$/i, String.trim(raw)) do
      [_, number] ->
        parse_size_number(number, "")

      [_, number, unit] ->
        parse_size_number(number, unit)

      _ ->
        nil
    end
  end

  defp parse_size_number(number, unit) do
    case Float.parse(number) do
      {value, ""} ->
        multiplier =
          case String.upcase(unit) do
            "" -> 1
            "K" -> 1_024
            "M" -> 1_024 * 1_024
            "G" -> 1_024 * 1_024 * 1_024
            "T" -> 1_024 * 1_024 * 1_024 * 1_024
            "P" -> 1_024 * 1_024 * 1_024 * 1_024 * 1_024
            _ -> nil
          end

        if is_integer(multiplier), do: trunc(value * multiplier), else: nil

      _ ->
        nil
    end
  end
end
