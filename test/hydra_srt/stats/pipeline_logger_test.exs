defmodule HydraSrt.Stats.PipelineLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HydraSrt.Stats.Duckdb
  alias HydraSrt.Stats.PipelineLogger

  setup do
    :ok = Duckdb.ensure_schema()
    :ok
  end

  test "flush_logs persists buffered rows to duckdb" do
    route_id = unique_route_id()
    ts = DateTime.utc_now() |> DateTime.truncate(:second)

    logs = [
      %{
        route_id: route_id,
        level: "ERROR",
        category: "srt",
        message: "persisted error",
        ts: ts
      }
    ]

    assert {[], %{}} = PipelineLogger.flush_logs(logs)

    assert eventually(fn ->
             case fetch_latest_message(route_id) do
               {:ok, "persisted error"} -> true
               _ -> false
             end
           end)
  end

  test "flush_logs writes synthetic WARN row when verbose lines were rate limited" do
    route_id = unique_route_id()

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

    assert {[], %{}} = PipelineLogger.flush_logs(logs, rate_counters)

    assert eventually(fn ->
             case fetch_latest_message(route_id) do
               {:ok, "rate limited: dropped 7 lines"} -> true
               _ -> false
             end
           end)

    assert eventually(fn ->
             case fetch_latest_level(route_id) do
               {:ok, "WARN"} -> true
               _ -> false
             end
           end)
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
             PipelineLogger.flush_logs(logs, %{}, fn _rows -> {:error, :duckdb_down} end)

    assert length(kept_logs) == 1
    assert hd(kept_logs).message == "boom"

    log =
      capture_log(fn ->
        assert {^kept_logs, %{}} =
                 PipelineLogger.flush_logs(kept_logs, %{}, fn _rows -> {:error, :duckdb_down} end)
      end)

    assert log =~ "PipelineLogger flush failed"
  end

  test "GenServer flush persists logs via duckdb" do
    route_id = unique_route_id()

    send(
      PipelineLogger,
      {:pipeline_log, %{route_id: route_id, level: "ERROR", category: "srt", message: "via genserver"}}
    )

    send(PipelineLogger, :flush)

    assert eventually(fn ->
             case fetch_latest_message(route_id) do
               {:ok, "via genserver"} -> true
               _ -> false
             end
           end)
  end

  defp unique_route_id do
    "route-pl-logger-#{System.unique_integer([:positive])}"
  end

  defp fetch_latest_message(route_id) do
    sql = """
    SELECT message
    FROM pipeline_logs
    WHERE route_id = ?
    ORDER BY ts DESC
    LIMIT 1
    """

    case Adbc.Connection.query(HydraSrt.AnalyticsConn, sql, [route_id]) do
      {:ok, result} ->
        case Adbc.Result.to_map(result)["message"] do
          [message | _] -> {:ok, message}
          _ -> :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  defp fetch_latest_level(route_id) do
    sql = """
    SELECT level
    FROM pipeline_logs
    WHERE route_id = ?
    ORDER BY ts DESC
    LIMIT 1
    """

    case Adbc.Connection.query(HydraSrt.AnalyticsConn, sql, [route_id]) do
      {:ok, result} ->
        case Adbc.Result.to_map(result)["level"] do
          [level | _] -> {:ok, level}
          _ -> :not_found
        end

      {:error, _} ->
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
