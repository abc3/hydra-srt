defmodule HydraSrt.Stats.PipelineLogsAnalyticsTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Stats.Analytics
  alias HydraSrt.Stats.Duckdb

  setup do
    :ok = Duckdb.ensure_schema()
    :ok
  end

  test "insert_pipeline_logs and to_pipeline_log_columns round-trip sample rows" do
    route_id = unique_route_id()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row = %{
      ts: now,
      route_id: route_id,
      gst_ts: "0:00:01.000000000",
      pid: 42,
      thread_id: "0xabc",
      level: "WARN",
      category: "srt",
      element: "srt-src",
      file: "src/srt.c",
      line: 10,
      function: "connect",
      message: "connection failed",
      dropped_count: 0
    }

    columns = Duckdb.to_pipeline_log_columns([row])
    assert length(columns) == 13
    assert Enum.at(columns, 0).field.name == "ts"
    assert Enum.at(columns, 5).field.name == "level"

    assert :ok = Duckdb.insert_pipeline_logs([row])

    assert {:ok, %{logs: logs}} =
             Analytics.fetch_route_pipeline_logs(route_id, %{
               "from" => DateTime.to_iso8601(DateTime.add(now, -1, :hour)),
               "to" => DateTime.to_iso8601(DateTime.add(now, 1, :hour))
             })

    assert [%{"level" => "WARN", "message" => "connection failed"} | _] = logs
  end

  test "fetch_route_pipeline_logs filters by window, levels, categories, limit, offset, and meta.total" do
    route_id = unique_route_id()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows = [
      pipeline_log_row(route_id, now, "ERROR", "srt", "error one"),
      pipeline_log_row(route_id, DateTime.add(now, -1, :second), "WARN", "srt", "warn one"),
      pipeline_log_row(route_id, DateTime.add(now, -2, :second), "INFO", "net", "info one"),
      pipeline_log_row(route_id, DateTime.add(now, -3, :second), "DEBUG", "net", "debug one")
    ]

    assert :ok = Duckdb.insert_pipeline_logs(rows)

    assert {:ok, %{logs: filtered_logs, meta: meta}} =
             Analytics.fetch_route_pipeline_logs(route_id, %{
               "window" => "last_hour",
               "levels" => "ERROR,WARN",
               "categories" => "srt",
               "limit" => "1",
               "offset" => "0"
             })

    assert length(filtered_logs) == 1
    assert hd(filtered_logs)["level"] in ["ERROR", "WARN"]
    assert hd(filtered_logs)["category"] == "srt"
    assert meta.window == "last_hour"
    assert meta.limit == 1
    assert meta.offset == 0
    assert meta.levels == ["ERROR", "WARN"]
    assert meta.categories == ["srt"]
    assert meta.total == 2

    assert {:ok, %{logs: offset_logs, meta: offset_meta}} =
             Analytics.fetch_route_pipeline_logs(route_id, %{
               "window" => "last_hour",
               "levels" => "ERROR,WARN",
               "categories" => "srt",
               "limit" => "1",
               "offset" => "1"
             })

    assert length(offset_logs) == 1
    assert offset_meta.total == 2
    refute hd(filtered_logs)["message"] == hd(offset_logs)["message"]
  end

  test "fetch_route_pipeline_log_distinct returns sorted level and category values" do
    route_id = unique_route_id()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert :ok =
             Duckdb.insert_pipeline_logs([
               pipeline_log_row(route_id, now, "WARN", "srt", "a"),
               pipeline_log_row(route_id, DateTime.add(now, -1, :second), "ERROR", "net", "b"),
               pipeline_log_row(route_id, DateTime.add(now, -2, :second), "WARN", "net", "c")
             ])

    assert {:ok, levels} = Analytics.fetch_route_pipeline_log_distinct(route_id, "level")
    assert levels == ["ERROR", "WARN"]

    assert {:ok, categories} =
             Analytics.fetch_route_pipeline_log_distinct(route_id, "category")

    assert categories == ["net", "srt"]
  end

  test "fetch_route_pipeline_log_distinct rejects invalid column" do
    assert {:error, {:bad_request, "Invalid column"}} =
             Analytics.fetch_route_pipeline_log_distinct("route-1", "message")
  end

  defp unique_route_id do
    "route-pl-analytics-#{System.unique_integer([:positive])}"
  end

  defp pipeline_log_row(route_id, ts, level, category, message) do
    %{
      ts: ts,
      route_id: route_id,
      gst_ts: "0:00:00.000000000",
      pid: 1,
      thread_id: "0x1",
      level: level,
      category: category,
      element: nil,
      file: nil,
      line: nil,
      function: nil,
      message: message,
      dropped_count: 0
    }
  end
end
