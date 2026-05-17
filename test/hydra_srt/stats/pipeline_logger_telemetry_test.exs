defmodule HydraSrt.Stats.PipelineLoggerTelemetryTest do
  use ExUnit.Case, async: false

  alias HydraSrt.PipelineLogTelemetry
  alias HydraSrt.Stats.PipelineLogger

  @stored_event PipelineLogTelemetry.stored_event()
  @dropped_event PipelineLogTelemetry.dropped_event()

  setup do
    test_pid = self()

    stored_handler = "pipeline-logger-stored-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        stored_handler,
        @stored_event,
        fn event, measurements, metadata, receiver ->
          send(receiver, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(stored_handler) end)

    {:ok, test_pid: test_pid}
  end

  test "emit stored telemetry when buffering a non-verbose log line" do
    send(
      PipelineLogger,
      {:pipeline_log, %{route_id: "route-pl-1", level: "ERROR", message: "boom"}}
    )

    assert_receive {:telemetry, @stored_event, %{count: 1},
                    %{route_id: "route-pl-1", level: "ERROR"}}
  end

  test "emit dropped telemetry when verbose log line is rate limited", %{test_pid: test_pid} do
    dropped_handler = "pipeline-logger-dropped-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        dropped_handler,
        @dropped_event,
        fn event, measurements, metadata, receiver ->
          send(receiver, {:telemetry_dropped, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(dropped_handler) end)

    # Matches PipelineLogger @default_max_verbose_per_window
    max_verbose = 200

    for i <- 1..max_verbose do
      send(
        PipelineLogger,
        {:pipeline_log, %{route_id: "route-pl-verbose", level: "DEBUG", message: "verbose #{i}"}}
      )

      assert_receive {:telemetry, @stored_event, %{count: 1},
                      %{route_id: "route-pl-verbose", level: "DEBUG"}}
    end

    send(
      PipelineLogger,
      {:pipeline_log,
       %{route_id: "route-pl-verbose", level: "DEBUG", message: "verbose overflow"}}
    )

    assert_receive {:telemetry_dropped, @dropped_event, %{count: 1},
                    %{route_id: "route-pl-verbose", level: "DEBUG"}}
  end
end
