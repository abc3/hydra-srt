defmodule HydraSrt.PromEx.Plugins.OsMon do
  @moduledoc """
  Polls os_mon metrics.
  """

  use PromEx.Plugin
  require Logger

  alias HydraSrt.Monitoring.NetIf
  alias HydraSrt.Monitoring.NetIfMetrics
  alias HydraSrt.Monitoring.OsMonTelemetry

  @prefix [:hydra_srt, :prom_ex]
  @cache_key {__MODULE__, :last_stats}
  @net_prev_key {__MODULE__, :net_prev_snapshot}
  @net_prev_ts_key {__MODULE__, :net_prev_ts_ms}

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate)

    [
      metrics(poll_rate)
    ]
  end

  defp metrics(poll_rate) do
    Polling.build(
      :hydra_srt_osmon_events,
      poll_rate,
      {__MODULE__, :execute_metrics, []},
      [
        last_value(
          @prefix ++ [:osmon, :ram_usage],
          event_name: OsMonTelemetry.ram_usage_event(),
          description: "The total percentage usage of operative memory.",
          measurement: :ram
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :available],
          event_name: OsMonTelemetry.memory_event(),
          description: "The total available memory in the operating system",
          unit: :bytes,
          measurement: :available
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :buffered],
          event_name: OsMonTelemetry.memory_event(),
          description: "The buffered memory in the operating system",
          unit: :bytes,
          measurement: :buffered
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :cached],
          event_name: OsMonTelemetry.memory_event(),
          description: "The cached memory in the operating system",
          unit: :bytes,
          measurement: :cached
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :free],
          event_name: OsMonTelemetry.memory_event(),
          description: "The free memory in the operating system",
          unit: :bytes,
          measurement: :free
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :total],
          event_name: OsMonTelemetry.memory_event(),
          description: "The total memory in the operating system",
          unit: :bytes,
          measurement: :total
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :system_total],
          event_name: OsMonTelemetry.memory_event(),
          description: "The total system memory",
          unit: :bytes,
          measurement: :system_total
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_util],
          event_name: OsMonTelemetry.cpu_util_event(),
          description:
            "The sum of the percentage shares of the CPU cycles spent in all busy processor states in average on all CPUs.",
          measurement: :cpu
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_avg1],
          event_name: OsMonTelemetry.cpu_la_event(),
          description: "The average system load in the last minute.",
          measurement: :avg1
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_avg5],
          event_name: OsMonTelemetry.cpu_la_event(),
          description: "The average system load in the last five minutes.",
          measurement: :avg5
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_avg15],
          event_name: OsMonTelemetry.cpu_la_event(),
          description: "The average system load in the last 15 minutes.",
          measurement: :avg15
        ),
        last_value(
          @prefix ++ [:osmon, :swap_usage],
          event_name: OsMonTelemetry.swap_usage_event(),
          description: "The total percentage usage of swap memory.",
          measurement: :swap
        ),
        last_value(
          @prefix ++ [:osmon, :net, :rx_bytes_total],
          event_name: OsMonTelemetry.network_interface_event(),
          description: "Total bytes received on the interface since boot.",
          unit: :bytes,
          measurement: :rx_bytes,
          tags: [:interface],
          tag_values: &net_tag_values/1
        ),
        last_value(
          @prefix ++ [:osmon, :net, :tx_bytes_total],
          event_name: OsMonTelemetry.network_interface_event(),
          description: "Total bytes transmitted on the interface since boot.",
          unit: :bytes,
          measurement: :tx_bytes,
          tags: [:interface],
          tag_values: &net_tag_values/1
        ),
        last_value(
          @prefix ++ [:osmon, :net, :rx_bytes_per_sec],
          event_name: OsMonTelemetry.network_interface_event(),
          description: "Bytes received per second on the interface.",
          unit: :bytes_per_second,
          measurement: :rx_bytes_per_sec,
          tags: [:interface],
          tag_values: &net_tag_values/1
        ),
        last_value(
          @prefix ++ [:osmon, :net, :tx_bytes_per_sec],
          event_name: OsMonTelemetry.network_interface_event(),
          description: "Bytes transmitted per second on the interface.",
          unit: :bytes_per_second,
          measurement: :tx_bytes_per_sec,
          tags: [:interface],
          tag_values: &net_tag_values/1
        )
      ]
    )
  end

  def execute_metrics do
    stats = %{
      ram: ram_usage(),
      cpu: cpu_util(),
      cpu_la: cpu_la(),
      swap: swap_usage(),
      memory: memory(),
      network: network_snapshot()
    }

    :persistent_term.put(@cache_key, stats)

    execute_metrics(OsMonTelemetry.memory_event(), stats.memory)
    execute_metrics(OsMonTelemetry.ram_usage_event(), %{ram: stats.ram})
    execute_metrics(OsMonTelemetry.cpu_util_event(), %{cpu: stats.cpu})
    execute_metrics(OsMonTelemetry.cpu_la_event(), stats.cpu_la)
    execute_metrics(OsMonTelemetry.swap_usage_event(), %{swap: stats.swap})

    Enum.each(stats.network, fn {iface, measurements} ->
      execute_metrics(OsMonTelemetry.network_interface_event(), measurements, %{interface: iface})
    end)
  end

  def execute_metrics(event, metrics) do
    execute_metrics(event, metrics, %{})
  end

  def execute_metrics(event, metrics, metadata) do
    :telemetry.execute(event, metrics, metadata)
  end

  @spec get_stats() :: map() | nil
  def get_stats do
    :persistent_term.get(@cache_key, nil)
  end

  @spec ram_usage() :: float()
  def ram_usage do
    mem = :memsup.get_system_memory_data()
    100 - mem[:free_memory] / mem[:total_memory] * 100
  end

  @spec memory() :: map()
  def memory do
    data = :memsup.get_system_memory_data()

    %{
      available: data[:available_memory],
      buffered: data[:buffered_memory],
      cached: data[:cached_memory],
      free: data[:free_memory],
      total: data[:total_memory],
      system_total: data[:system_total_memory]
    }
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
      100 - free_swap / total_swap * 100
    else
      _ -> nil
    end
  end

  defp network_snapshot do
    now_ms = System.monotonic_time(:millisecond)
    current = NetIf.snapshot()
    previous = :persistent_term.get(@net_prev_key, %{})
    previous_ts = :persistent_term.get(@net_prev_ts_key, now_ms)
    delta_ms = max(now_ms - previous_ts, 0)
    rates = NetIf.rates(previous, current, delta_ms)

    :persistent_term.put(@net_prev_key, current)
    :persistent_term.put(@net_prev_ts_key, now_ms)

    current
    |> Enum.reject(fn {iface, _} -> loopback_iface?(iface) end)
    |> Enum.into(%{}, fn {iface, counters} ->
      rate_values = Map.get(rates, iface, %{})
      merged = merge_network_rates(counters, rate_values)
      {iface, merged}
    end)
  end

  defp merge_network_rates(counters, rate_values) do
    Enum.reduce(NetIfMetrics.counter_keys(), counters, fn key, acc ->
      value = Map.get(rate_values, key)
      Map.put(acc, :"#{key}_per_sec", value)
    end)
  end

  defp loopback_iface?(iface) when is_binary(iface) do
    iface == "lo" or iface == "lo0" or String.starts_with?(iface, "lo")
  end

  defp loopback_iface?(_), do: false

  defp net_tag_values(metadata) when is_map(metadata) do
    %{interface: to_string(Map.get(metadata, :interface, "unknown"))}
  end
end
