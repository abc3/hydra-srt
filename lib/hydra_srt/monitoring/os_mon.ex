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
          cpu_la: %{avg1: float(), avg5: float(), avg15: float()}
        }
  def get_all_stats do
    %{
      cpu: cpu_util(),
      ram: ram_usage(),
      swap: swap_usage(),
      cpu_la: cpu_la()
    }
  end

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
