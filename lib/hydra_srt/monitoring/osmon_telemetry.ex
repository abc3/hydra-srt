defmodule HydraSrt.Monitoring.OsMonTelemetry do
  @moduledoc false

  @event_memory [:prom_ex, :plugin, :osmon, :memory]
  @event_ram_usage [:prom_ex, :plugin, :osmon, :ram_usage]
  @event_cpu_util [:prom_ex, :plugin, :osmon, :cpu_util]
  @event_cpu_la [:prom_ex, :plugin, :osmon, :cpu_avg1]
  @event_swap_usage [:prom_ex, :plugin, :osmon, :swap_usage]

  @spec memory_event() :: [atom()]
  def memory_event, do: @event_memory

  @spec ram_usage_event() :: [atom()]
  def ram_usage_event, do: @event_ram_usage

  @spec cpu_util_event() :: [atom()]
  def cpu_util_event, do: @event_cpu_util

  @spec cpu_la_event() :: [atom()]
  def cpu_la_event, do: @event_cpu_la

  @spec swap_usage_event() :: [atom()]
  def swap_usage_event, do: @event_swap_usage

  @spec all_events() :: [[atom()]]
  def all_events do
    [
      memory_event(),
      ram_usage_event(),
      cpu_util_event(),
      cpu_la_event(),
      swap_usage_event()
    ]
  end
end
