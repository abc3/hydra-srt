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

  test "dedups repeated identical WARN lines but always keeps the first occurrence" do
    route_id = unique_route_id()
    name = :"pipeline_logger_dedup_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {PipelineLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           insert_logs_fun: fn _rows -> {:error, :victoria_logs_down} end
         }}
      )

    reconnect_line = %{
      route_id: route_id,
      level: "WARN",
      category: "srtobject",
      element: "srtsrc0",
      message: "Error on SRT socket: Connection timeout (16). Trying to reconnect"
    }

    for _ <- 1..5, do: send(name, {:pipeline_log, reconnect_line})
    _ = :sys.get_state(pid)

    state = :sys.get_state(pid)

    # Only the first occurrence was buffered; the other four identical repeats
    # were suppressed (not silently discarded - the counter below proves it).
    assert Enum.count(state.logs, &(&1.message == reconnect_line.message)) == 1
    [{_signature, entry}] = Map.to_list(state.rate_counters[route_id].dedup)
    assert entry.dropped == 4
  end

  test "dedup is robust to two distinct WARN shapes interleaving every cycle" do
    # This is the actual dead-port failure pattern: a stats-read failure and a
    # bus reconnect notice alternate every ~3s, byte-identical within their own
    # kind. A single shared dedup slot lets each one stomp the other's pending
    # state before its own repeat is ever recognised, so nothing gets
    # suppressed at all. Independent per-signature slots must dedup both.
    route_id = unique_route_id()
    name = :"pipeline_logger_dedup_interleave_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {PipelineLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           insert_logs_fun: fn _rows -> {:error, :victoria_logs_down} end
         }}
      )

    stats_failure = %{
      route_id: route_id,
      level: "WARN",
      category: "srtobject",
      element: "srtsrc0",
      message: "failed to retrieve stats for socket 47 (reason Connection does not exist)"
    }

    reconnect_notice = %{
      route_id: route_id,
      level: "WARN",
      category: "srtobject",
      element: "srtsrc0",
      message: "Error on SRT socket: Connection timeout (16). Trying to reconnect"
    }

    for _ <- 1..10 do
      send(name, {:pipeline_log, stats_failure})
      send(name, {:pipeline_log, reconnect_notice})
    end

    _ = :sys.get_state(pid)
    state = :sys.get_state(pid)

    # Both first occurrences passed through, nothing else did.
    assert Enum.count(state.logs, &(&1.message == stats_failure.message)) == 1
    assert Enum.count(state.logs, &(&1.message == reconnect_notice.message)) == 1

    dedup = state.rate_counters[route_id].dedup
    assert map_size(dedup) == 2
    assert Enum.all?(Map.values(dedup), &(&1.dropped == 9))
  end

  test "dedup normalizes the volatile socket id so a changing handle number still counts as a repeat" do
    route_id = unique_route_id()
    name = :"pipeline_logger_dedup_volatile_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {PipelineLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           insert_logs_fun: fn _rows -> {:error, :victoria_logs_down} end
         }}
      )

    line = fn socket_id ->
      %{
        route_id: route_id,
        level: "WARN",
        category: "srtobject",
        element: "srtsrc0",
        message:
          "failed to retrieve stats for socket #{socket_id} (reason Connection does not exist)"
      }
    end

    for socket_id <- [12, 47, 88, 103], do: send(name, {:pipeline_log, line.(socket_id)})
    _ = :sys.get_state(pid)

    state = :sys.get_state(pid)

    # Only the very first (socket 12) landed - the later ones only differ by
    # the volatile socket handle, so they are recognised as the same repeat.
    assert length(state.logs) == 1
    assert hd(state.logs).message =~ "socket 12"

    [{_signature, entry}] = Map.to_list(state.rate_counters[route_id].dedup)
    assert entry.dropped == 3
  end

  test "dedup does not collapse two genuinely different messages that merely contain different numbers" do
    route_id = unique_route_id()
    name = :"pipeline_logger_dedup_distinct_numbers_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {PipelineLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           insert_logs_fun: fn _rows -> {:error, :victoria_logs_down} end
         }}
      )

    timeout_line = %{
      route_id: route_id,
      level: "WARN",
      category: "srtobject",
      message: "Error on SRT socket: Connection timeout (16). Trying to reconnect"
    }

    refused_line = %{
      route_id: route_id,
      level: "WARN",
      category: "srtobject",
      message: "Error on SRT socket: Connection refused (17). Trying to reconnect"
    }

    send(name, {:pipeline_log, timeout_line})
    send(name, {:pipeline_log, refused_line})
    _ = :sys.get_state(pid)

    state = :sys.get_state(pid)
    messages = Enum.map(state.logs, & &1.message)

    # Both are distinct error codes, not a volatile socket handle - neither
    # may be treated as a repeat of the other.
    assert timeout_line.message in messages
    assert refused_line.message in messages
    assert map_size(state.rate_counters[route_id].dedup) == 2
  end

  test "flush_logs materializes a suppressed WARN tally without losing the first occurrence" do
    route_id = unique_route_id()
    test_pid = self()

    line = %{
      route_id: route_id,
      level: "WARN",
      category: "srtobject",
      message: "Error on SRT socket: Connection timeout (16). Trying to reconnect",
      ts: DateTime.utc_now()
    }

    signature = {line.level, line.category, nil, line.message}

    rate_counters = %{
      route_id => %{
        count: 0,
        dropped: 0,
        dedup: %{signature => %{dropped: 6, sample: line}}
      }
    }

    assert {[], counters_after} =
             PipelineLogger.flush_logs([line], rate_counters, fn rows ->
               send(test_pid, {:inserted_logs, rows})
               :ok
             end)

    assert_receive {:inserted_logs, rows}, 500

    synthetic = Enum.find(rows, &(&1.message =~ "suppressed 6 duplicate log lines"))
    assert synthetic.level == "WARN"
    assert synthetic.route_id == route_id
    assert synthetic.message =~ line.message

    assert Enum.any?(rows, &(&1.message == line.message))

    # Dedup memory for this exact signature survives the flush (unlike the
    # verbose count budget) so an unbroken repeat keeps being suppressed
    # across flush windows instead of being re-admitted every tick.
    assert Map.has_key?(counters_after[route_id].dedup, signature)
    assert counters_after[route_id].dedup[signature].dropped == 0
  end

  test "per-route dedup table is bounded: a flood of distinct messages evicts the coldest without losing counts" do
    route_id = unique_route_id()
    name = :"pipeline_logger_dedup_bound_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {PipelineLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           insert_logs_fun: fn _rows -> {:error, :victoria_logs_down} end
         }}
      )

    line = fn i ->
      %{
        route_id: route_id,
        level: "ERROR",
        category: "gst_bus",
        message: "distinct pathological message shape #{i}"
      }
    end

    # More distinct signatures than the cap allows.
    for i <- 1..40, do: send(name, {:pipeline_log, line.(i)})
    _ = :sys.get_state(pid)

    state = :sys.get_state(pid)

    assert map_size(state.rate_counters[route_id].dedup) <= 32
  end

  defp unique_route_id do
    "route-pl-logger-#{System.unique_integer([:positive])}"
  end
end
