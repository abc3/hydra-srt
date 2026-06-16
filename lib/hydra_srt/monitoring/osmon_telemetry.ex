defmodule HydraSrt.Monitoring.OsMonTelemetry do
  @moduledoc false

  @event_memory [:prom_ex, :plugin, :osmon, :memory]
  @event_ram_usage [:prom_ex, :plugin, :osmon, :ram_usage]
  @event_cpu_util [:prom_ex, :plugin, :osmon, :cpu_util]
  @event_cpu_la [:prom_ex, :plugin, :osmon, :cpu_avg1]
  @event_swap_usage [:prom_ex, :plugin, :osmon, :swap_usage]
  @event_network_interface [:prom_ex, :plugin, :osmon, :network_interface]
  @event_storage [:prom_ex, :plugin, :osmon, :storage]
  @event_database [:prom_ex, :plugin, :osmon, :database]

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

  @spec network_interface_event() :: [atom()]
  def network_interface_event, do: @event_network_interface

  @spec storage_event() :: [atom()]
  def storage_event, do: @event_storage

  @spec database_event() :: [atom()]
  def database_event, do: @event_database

  @spec all_events() :: [[atom()]]
  def all_events do
    [
      memory_event(),
      ram_usage_event(),
      cpu_util_event(),
      cpu_la_event(),
      swap_usage_event(),
      network_interface_event(),
      storage_event(),
      database_event()
    ]
  end
end
