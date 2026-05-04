defmodule HydraSrt.PromEx.Plugins.OsMon do
  @moduledoc """
  Polls os_mon metrics.
  """

  use PromEx.Plugin
  require Logger

  @event_memory [:prom_ex, :plugin, :osmon, :memory]
  @event_ram_usage [:prom_ex, :plugin, :osmon, :ram_usage]
  @event_cpu_util [:prom_ex, :plugin, :osmon, :cpu_util]
  @event_cpu_la [:prom_ex, :plugin, :osmon, :cpu_avg1]
  @event_swap_usage [:prom_ex, :plugin, :osmon, :swap_usage]
  @prefix [:hydra_srt, :prom_ex]
  @cache_key {__MODULE__, :last_stats}

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
          event_name: @event_ram_usage,
          description: "The total percentage usage of operative memory.",
          measurement: :ram
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :available],
          event_name: @event_memory,
          description: "The total available memory in the operating system",
          unit: :bytes,
          measurement: :available
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :buffered],
          event_name: @event_memory,
          description: "The buffered memory in the operating system",
          unit: :bytes,
          measurement: :buffered
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :cached],
          event_name: @event_memory,
          description: "The cached memory in the operating system",
          unit: :bytes,
          measurement: :cached
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :free],
          event_name: @event_memory,
          description: "The free memory in the operating system",
          unit: :bytes,
          measurement: :free
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :total],
          event_name: @event_memory,
          description: "The total memory in the operating system",
          unit: :bytes,
          measurement: :total
        ),
        last_value(
          @prefix ++ [:osmon, :memory, :system_total],
          event_name: @event_memory,
          description: "The total system memory",
          unit: :bytes,
          measurement: :system_total
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_util],
          event_name: @event_cpu_util,
          description:
            "The sum of the percentage shares of the CPU cycles spent in all busy processor states in average on all CPUs.",
          measurement: :cpu
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_avg1],
          event_name: @event_cpu_la,
          description: "The average system load in the last minute.",
          measurement: :avg1
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_avg5],
          event_name: @event_cpu_la,
          description: "The average system load in the last five minutes.",
          measurement: :avg5
        ),
        last_value(
          @prefix ++ [:osmon, :cpu_avg15],
          event_name: @event_cpu_la,
          description: "The average system load in the last 15 minutes.",
          measurement: :avg15
        ),
        last_value(
          @prefix ++ [:osmon, :swap_usage],
          event_name: @event_swap_usage,
          description: "The total percentage usage of swap memory.",
          measurement: :swap
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
      memory: memory()
    }

    :persistent_term.put(@cache_key, stats)

    execute_metrics(@event_memory, stats.memory)
    execute_metrics(@event_ram_usage, %{ram: stats.ram})
    execute_metrics(@event_cpu_util, %{cpu: stats.cpu})
    execute_metrics(@event_cpu_la, stats.cpu_la)
    execute_metrics(@event_swap_usage, %{swap: stats.swap})
  end

  def execute_metrics(event, metrics) do
    :telemetry.execute(event, metrics, %{})
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
end
