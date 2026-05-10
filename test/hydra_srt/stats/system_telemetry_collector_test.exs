defmodule HydraSrt.Stats.SystemTelemetryCollectorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HydraSrt.Monitoring.OsMonTelemetry
  alias HydraSrt.Stats.Duckdb
  alias HydraSrt.Stats.SystemTelemetryCollector

  test "rows_from_telemetry maps cpu mem swap la and net metrics" do
    cpu_rows =
      SystemTelemetryCollector.rows_from_telemetry(
        [:prom_ex, :plugin, :osmon, :cpu_util],
        %{cpu: 42.5}
      )

    ram_rows =
      SystemTelemetryCollector.rows_from_telemetry(
        [:prom_ex, :plugin, :osmon, :ram_usage],
        %{ram: 70.1}
      )

    swap_rows =
      SystemTelemetryCollector.rows_from_telemetry(
        [:prom_ex, :plugin, :osmon, :swap_usage],
        %{swap: 12.0}
      )

    la_rows =
      SystemTelemetryCollector.rows_from_telemetry(
        [:prom_ex, :plugin, :osmon, :cpu_avg1],
        %{avg1: 0.5, avg5: 0.8, avg15: 1.0}
      )

    memory_rows =
      SystemTelemetryCollector.rows_from_telemetry(
        [:prom_ex, :plugin, :osmon, :memory],
        %{available: 1, buffered: 2, cached: 3, free: 4, total: 5, system_total: 6}
      )

    net_rows =
      SystemTelemetryCollector.rows_from_telemetry(
        [:prom_ex, :plugin, :osmon, :network_interface],
        %{
          interface: "eth0",
          rx_bytes: 1000,
          tx_bytes: 2000,
          rx_packets: 10,
          tx_packets: 20,
          rx_errors: 1,
          tx_errors: 2,
          rx_dropped: 3,
          tx_dropped: 4,
          rx_bytes_per_sec: 100.0,
          tx_bytes_per_sec: 200.0
        }
      )

    assert Enum.map(cpu_rows, & &1.metric_key) == ["cpu_util"]
    assert Enum.map(ram_rows, & &1.metric_key) == ["ram_usage"]
    assert Enum.map(swap_rows, & &1.metric_key) == ["swap_usage"]
    assert Enum.map(la_rows, & &1.metric_key) == ["cpu_la_avg1", "cpu_la_avg5", "cpu_la_avg15"]

    assert Enum.map(memory_rows, & &1.metric_key) |> Enum.sort() == [
             "memory_available_bytes",
             "memory_buffered_bytes",
             "memory_cached_bytes",
             "memory_free_bytes",
             "memory_system_total_bytes",
             "memory_total_bytes"
           ]

    assert Enum.all?(net_rows, &(&1.entity_type == "net_if"))
    assert Enum.all?(net_rows, &(&1.entity_id == "eth0"))

    assert Enum.map(net_rows, & &1.metric_key) |> Enum.sort() == [
             "net_rx_bytes_per_sec",
             "net_rx_bytes_total",
             "net_rx_dropped_total",
             "net_rx_errors_total",
             "net_rx_packets_total",
             "net_tx_bytes_per_sec",
             "net_tx_bytes_total",
             "net_tx_dropped_total",
             "net_tx_errors_total",
             "net_tx_packets_total"
           ]
  end

  test "telemetry cpu event is persisted to duckdb" do
    start_supervised!(
      {SystemTelemetryCollector,
       enabled: true,
       flush_interval_ms: 60_000,
       max_batch_size: 1,
       metrics: [:cpu],
       name: :system_telemetry_collector_test,
       handler_prefix: "stats-osmon-test-#{System.unique_integer([:positive])}"}
    )

    :ok = Duckdb.ensure_schema()

    expected = 42.5
    :telemetry.execute(OsMonTelemetry.cpu_util_event(), %{cpu: expected}, %{})

    assert eventually(fn ->
             case fetch_latest_cpu_util() do
               {:ok, value} -> abs(value - expected) < 0.0001
               _ -> false
             end
           end)
  end

  test "enforces max_buffer_size by dropping old rows" do
    handler_prefix = "stats-osmon-test-#{System.unique_integer([:positive])}"
    name = :"system_telemetry_limit_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {SystemTelemetryCollector,
         enabled: true,
         flush_interval_ms: 100_000,
         max_batch_size: 100,
         max_buffer_size: 5,
         metrics: [:cpu],
         name: name,
         handler_prefix: handler_prefix}
      )

    log =
      capture_log(fn ->
        for i <- 1..10 do
          :telemetry.execute(OsMonTelemetry.cpu_util_event(), %{cpu: i * 1.0}, %{})
        end

        _ = :sys.get_state(pid)
      end)

    assert log =~ "dropped"
    assert log =~ "max_buffer_size"

    state = :sys.get_state(pid)
    assert state.row_count == 5
    assert Enum.map(state.rows, & &1.value_double) == [10.0, 9.0, 8.0, 7.0, 6.0]
  end

  defp fetch_latest_cpu_util do
    sql = """
    SELECT value_double
    FROM stats_samples
    WHERE entity_type = 'node' AND metric_key = 'cpu_util'
    ORDER BY ts DESC
    LIMIT 1
    """

    case Adbc.Connection.query(HydraSrt.AnalyticsConn, sql, []) do
      {:ok, result} ->
        columns = Adbc.Result.to_map(result)

        case Map.get(columns, "value_double", []) do
          [value | _] when is_number(value) -> {:ok, value * 1.0}
          _ -> :not_found
        end

      {:error, _reason} ->
        :not_found
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
