defmodule HydraSrt.Stats.VictoriaLogsTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.VictoriaLogs

  test "route_query targets hydra stream and escapes route id" do
    assert VictoriaLogs.route_query(~s(route"1)) ==
             ~s({app="hydra_srt",route_id="route\\"1"})
  end

  test "route_query pushes level and category filters into LogsQL" do
    assert VictoriaLogs.route_query("route-1", ["ERROR", "WARN"], ["srt"]) ==
             "{app=\"hydra_srt\",route_id=\"route-1\"} level:in(\"ERROR\",\"WARN\") category:in(\"srt\")"
  end

  test "routes_query batches all route ids into a single route_id:in filter" do
    assert VictoriaLogs.routes_query(["route-1", "route-2"]) ==
             ~s|{app="hydra_srt"} route_id:in("route-1","route-2")|
  end

  test "routes_query without ids selects the whole app stream" do
    assert VictoriaLogs.routes_query([]) == ~s|{app="hydra_srt"}|
  end

  test "summary_result on empty route list returns zeroed summary without querying" do
    assert VictoriaLogs.summary_result([]) == {:ok, VictoriaLogs.empty_summary()}
  end

  test "level_stats_query aggregates counts server-side per route and level" do
    assert VictoriaLogs.level_stats_query(["route-1", "route-2"]) ==
             ~s|{app="hydra_srt"} route_id:in("route-1","route-2") | <>
               "| stats by (route_id, level) count() rows"
  end

  test "last_error_query filters error/fatal and bounds the scan window" do
    assert VictoriaLogs.last_error_query(["route-1"]) ==
             ~s|{app="hydra_srt"} route_id:in("route-1") level:in("ERROR","FATAL") | <>
               "| sort by (_time desc) | limit 200"
  end

  test "level_counts_from_stats sums per-route buckets without truncation" do
    stats_rows = [
      %{"route_id" => "route-1", "level" => "WARN", "rows" => "6"},
      %{"route_id" => "route-1", "level" => "ERROR", "rows" => "2"},
      %{"route_id" => "route-2", "level" => "error", "rows" => "3"},
      %{"route_id" => "route-2", "level" => "INFO", "rows" => "10"},
      %{"route_id" => "route-2", "level" => "FATAL", "rows" => "1"},
      %{"route_id" => "route-2", "level" => "DEBUG", "rows" => "99"}
    ]

    assert VictoriaLogs.level_counts_from_stats(stats_rows) == %{
             errors: 6,
             warnings: 6,
             info: 10
           }
  end

  test "latest_error_from_rows picks the most recent error and ignores non-errors" do
    rows = [
      %{
        "level" => "ERROR",
        "ts" => "2026-01-01T00:00:01Z",
        "route_id" => "r1",
        "message" => "old"
      },
      %{
        "level" => "WARN",
        "ts" => "2026-01-01T00:00:09Z",
        "route_id" => "r2",
        "message" => "warn"
      },
      %{
        "level" => "FATAL",
        "ts" => "2026-01-01T00:00:05Z",
        "route_id" => "r3",
        "message" => "new"
      }
    ]

    assert VictoriaLogs.latest_error_from_rows(rows)["message"] == "new"
    assert VictoriaLogs.latest_error_from_rows([]) == nil
  end

  test "summary_from_level_stats produces the dashboard summary shape" do
    stats_rows = [
      %{"route_id" => "r1", "level" => "ERROR", "rows" => "2"},
      %{"route_id" => "r1", "level" => "WARN", "rows" => "4"},
      %{"route_id" => "r2", "level" => "INFO", "rows" => "7"}
    ]

    error_rows = [
      %{
        "level" => "ERROR",
        "ts" => "2026-01-01T00:00:05Z",
        "route_id" => "r1",
        "message" => "boom"
      }
    ]

    assert VictoriaLogs.summary_from_level_stats(stats_rows, error_rows) == %{
             errors: 2,
             warnings: 4,
             info: 7,
             last_error_at: "2026-01-01T00:00:05Z",
             last_error_route_id: "r1",
             last_error_message: "boom"
           }
  end

  test "inspect_stream_value neutralizes newlines, carriage returns and control chars" do
    assert VictoriaLogs.inspect_stream_value("a\nb\r\tc") == ~s("a\\nb\\r\\tc")
    assert VictoriaLogs.inspect_stream_value("a\0b\ac") == ~s("abc")
    assert VictoriaLogs.inspect_stream_value(~s(a"b\\c)) == ~s("a\\"b\\\\c")
  end

  test "parse_stats_count reads LogsQL stats result" do
    assert VictoriaLogs.parse_stats_count(~s({"logs_total":"42"}\n)) == 42
    assert VictoriaLogs.parse_stats_count(~s({"logs_total":7}\n)) == 7
    assert VictoriaLogs.parse_stats_count("") == 0
  end

  test "parse_field_values handles JSON arrays and JSON lines" do
    assert VictoriaLogs.parse_field_values(~s(["WARN","ERROR"])) == ["ERROR", "WARN"]

    assert VictoriaLogs.parse_field_values(~s({"level":"INFO"}\n{"level":"ERROR"}\n)) == [
             "ERROR",
             "INFO"
           ]
  end

  test "json_log_to_row maps VictoriaLogs fields to API row shape" do
    row =
      VictoriaLogs.json_log_to_row(%{
        "_time" => "2026-01-01T00:00:00Z",
        "_msg" => "hello",
        "route_id" => "route-1",
        "level" => "WARN",
        "category" => "srt",
        "pid" => "42",
        "line" => "7"
      })

    assert row["ts"] == "2026-01-01T00:00:00Z"
    assert row["message"] == "hello"
    assert row["pid"] == 42
    assert row["line"] == 7
  end
end
