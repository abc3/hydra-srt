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

  @spec counter_keys() :: [atom()]
  def counter_keys, do: @counter_keys

  @spec total_metric_keys() :: %{atom() => binary()}
  def total_metric_keys, do: @total_metric_keys

  @spec rate_metric_keys() :: %{atom() => binary()}
  def rate_metric_keys, do: @rate_metric_keys
end
