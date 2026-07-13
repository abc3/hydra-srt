defmodule HydraSrt.Stats.PipelineLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HydraSrt.Stats.PipelineLogger

  test "flush_logs persists buffered rows to VictoriaLogs insert callback" do
    route_id = unique_route_id()
    ts = DateTime.utc_now() |> DateTime.truncate(:second)
    test_pid = self()

    logs = [
      %{
        route_id: route_id,
        level: "ERROR",
        category: "srt",
        message: "persisted error",
        ts: ts
      }
    ]

    assert {[], %{}} =
             PipelineLogger.flush_logs(logs, %{}, fn rows ->
               send(test_pid, {:inserted_logs, rows})
               :ok
             end)

    assert_receive {:inserted_logs, [row]}, 500
    assert row.route_id == route_id
    assert row.message == "persisted error"
    assert row.ts == ts
  end

  test "flush_logs writes synthetic WARN row when verbose lines were rate limited" do
    route_id = unique_route_id()
    test_pid = self()

    logs = [
      %{
        route_id: route_id,
        level: "DEBUG",
        category: "srt",
        message: "last verbose line",
        ts: DateTime.utc_now()
      }
    ]

    rate_counters = %{route_id => %{count: 200, dropped: 7}}

    assert {[], %{}} =
             PipelineLogger.flush_logs(logs, rate_counters, fn rows ->
               send(test_pid, {:inserted_logs, rows})
               :ok
             end)

    assert_receive {:inserted_logs, rows}, 500
    synthetic = Enum.find(rows, &(&1.message == "rate limited: dropped 7 lines"))
    assert synthetic.level == "WARN"
    assert synthetic.route_id == route_id
  end

  test "flush_logs keeps logs when insert fails" do
    logs = [
      %{
        route_id: "route-pl-flush-fail",
        level: "ERROR",
        message: "boom",
        ts: DateTime.utc_now()
      }
    ]

    assert {kept_logs, %{}} =
             PipelineLogger.flush_logs(logs, %{}, fn _rows -> {:error, :victoria_logs_down} end)

    assert length(kept_logs) == 1
    assert hd(kept_logs).message == "boom"

    log =
      capture_log(fn ->
        assert {^kept_logs, %{}} =
                 PipelineLogger.flush_logs(kept_logs, %{}, fn _rows ->
                   {:error, :victoria_logs_down}
                 end)
      end)

    assert log =~ "PipelineLogger flush failed"
  end

  test "enforces max_buffer_size by dropping oldest log lines" do
    name = :"pipeline_logger_limit_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {PipelineLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           max_buffer_size: 5,
           insert_logs_fun: fn _rows -> {:error, :victoria_logs_down} end
         }}
      )

    log =
      capture_log(fn ->
        for i <- 1..10 do
          send(name, {
            :pipeline_log,
            %{
              route_id: "route-1",
              level: "ERROR",
              category: "srt",
              message: "line #{i}"
            }
          })
        end

        _ = :sys.get_state(pid)
      end)

    assert log =~ "dropped"
    assert log =~ "max_buffer_size"

    state = :sys.get_state(pid)
    assert length(state.logs) == 5

    assert Enum.map(state.logs, & &1.message) == [
             "line 10",
             "line 9",
             "line 8",
             "line 7",
             "line 6"
           ]
  end

  test "flush_logs enforces max_buffer_size after insert failure" do
    logs =
      1..10
      |> Enum.map(fn i ->
        %{
          route_id: "route-1",
          level: "ERROR",
          category: "srt",
          message: "line #{i}",
          ts: DateTime.add(~U[2026-01-01 00:00:00Z], i, :second)
        }
      end)
      |> Enum.reverse()

    log =
      capture_log(fn ->
        {kept_logs, %{}} =
          PipelineLogger.flush_logs(
            logs,
            %{},
            fn _rows -> {:error, :victoria_logs_down} end,
            5
          )

        assert length(kept_logs) == 5

        assert Enum.map(kept_logs, & &1.message) == [
                 "line 10",
                 "line 9",
                 "line 8",
                 "line 7",
                 "line 6"
               ]
      end)

    assert log =~ "Pipeline logger dropped 5 buffered log lines due to max_buffer_size"
  end

  test "GenServer flush persists logs via injected insert callback" do
    route_id = unique_route_id()
    test_pid = self()
    name = :"pipeline_logger_flush_test_#{System.unique_integer([:positive])}"

    _pid =
      start_supervised!(
        {PipelineLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           insert_logs_fun: fn rows ->
             send(test_pid, {:inserted_logs, rows})
             :ok
           end
         }}
      )

    send(
      name,
      {:pipeline_log,
       %{route_id: route_id, level: "ERROR", category: "srt", message: "via genserver"}}
    )

    send(name, :flush)

    assert_receive {:inserted_logs, rows}, 500
    assert Enum.any?(rows, &(&1.route_id == route_id and &1.message == "via genserver"))
  end

  defp unique_route_id do
    "route-pl-logger-#{System.unique_integer([:positive])}"
  end
end
