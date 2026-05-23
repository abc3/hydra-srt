defmodule HydraSrt.Monitoring.NetIfMetrics do
  @moduledoc false

  @counter_keys [
    :rx_bytes,
    :tx_bytes,
    :rx_packets,
    :tx_packets,
    :rx_errors,
    :tx_errors,
    :rx_dropped,
    :tx_dropped
  ]

  @total_metric_keys %{
    rx_bytes: "net_rx_bytes_total",
    tx_bytes: "net_tx_bytes_total",
    rx_packets: "net_rx_packets_total",
    tx_packets: "net_tx_packets_total",
    rx_errors: "net_rx_errors_total",
    tx_errors: "net_tx_errors_total",
    rx_dropped: "net_rx_dropped_total",
    tx_dropped: "net_tx_dropped_total"
  }

  @rate_metric_keys %{
    rx_bytes: "net_rx_bytes_per_sec",
    tx_bytes: "net_tx_bytes_per_sec",
    rx_packets: "net_rx_packets_per_sec",
    tx_packets: "net_tx_packets_per_sec",
    rx_errors: "net_rx_errors_per_sec",
    tx_errors: "net_tx_errors_per_sec",
    rx_dropped: "net_rx_dropped_per_sec",
    tx_dropped: "net_tx_dropped_per_sec"
  }

  @rate_counter_keys %{
    rx_bytes: :rx_bytes_per_sec,
    tx_bytes: :tx_bytes_per_sec,
    rx_packets: :rx_packets_per_sec,
    tx_packets: :tx_packets_per_sec,
    rx_errors: :rx_errors_per_sec,
    tx_errors: :tx_errors_per_sec,
    rx_dropped: :rx_dropped_per_sec,
    tx_dropped: :tx_dropped_per_sec
  }

  @spec counter_keys() :: [atom()]
  def counter_keys, do: @counter_keys

  @spec total_metric_keys() :: %{atom() => binary()}
  def total_metric_keys, do: @total_metric_keys

  @spec rate_metric_keys() :: %{atom() => binary()}
  def rate_metric_keys, do: @rate_metric_keys

  @spec rate_counter_keys() :: %{atom() => atom()}
  def rate_counter_keys, do: @rate_counter_keys

  @spec rate_counter_key(atom()) :: atom()
  def rate_counter_key(counter_key) when is_atom(counter_key) do
    Map.fetch!(@rate_counter_keys, counter_key)
  end
end
