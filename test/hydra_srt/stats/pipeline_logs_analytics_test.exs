defmodule HydraSrt.Stats.PipelineLogsAnalyticsTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.Analytics
  alias HydraSrt.Stats.VictoriaLogs

  defmodule FakeVictoriaLogs do
    def query_route_logs(_route_id, params) do
      rows = [
        log_row("ERROR", "srt", "error one"),
        log_row("WARN", "srt", "warn one"),
        log_row("INFO", "net", "info one"),
        log_row("DEBUG", "net", "debug one")
      ]

      filtered =
        rows
        |> VictoriaLogs.filter_logs(params.levels, params.categories)

      {:ok,
       %{
         logs: filtered |> Enum.drop(params.offset) |> Enum.take(params.limit),
         total: length(filtered)
       }}
    end

    def distinct_route_values(_route_id, "level"), do: {:ok, ["ERROR", "WARN"]}
    def distinct_route_values(_route_id, "category"), do: {:ok, ["net", "srt"]}

    def log_row(level, category, message) do
      %{
        "ts" => "2026-01-01T00:00:00Z",
        "route_id" => "route-1",
        "level" => level,
        "category" => category,
        "message" => message
      }
    end
  end

  test "VictoriaLogs JSON line encoder preserves pipeline log fields" do
    now = ~U[2026-01-01 00:00:00Z]

    encoded =
      VictoriaLogs.log_to_json_line(%{
        ts: now,
        route_id: "route-1",
        level: "WARN",
        category: "srt",
        message: "connection failed",
        dropped_count: 0
      })

    assert {:ok, decoded} = Jason.decode(encoded)
    assert decoded["app"] == "hydra_srt"
    assert decoded["_time"] == DateTime.to_iso8601(now)
    assert decoded["_msg"] == "connection failed"
    assert decoded["route_id"] == "route-1"
    assert decoded["level"] == "WARN"
  end

  test "fetch_route_pipeline_logs filters by window, levels, categories, limit, offset, and meta.total" do
    assert {:ok, %{logs: filtered_logs, meta: meta}} =
             Analytics.fetch_route_pipeline_logs(
               "route-1",
               %{
                 "window" => "last_hour",
                 "levels" => "ERROR,WARN",
                 "categories" => "srt",
                 "limit" => "1",
                 "offset" => "0"
               },
               FakeVictoriaLogs
             )

    assert length(filtered_logs) == 1
    assert hd(filtered_logs)["level"] in ["ERROR", "WARN"]
    assert hd(filtered_logs)["category"] == "srt"
    assert meta.window == "last_hour"
    assert meta.limit == 1
    assert meta.offset == 0
    assert meta.levels == ["ERROR", "WARN"]
    assert meta.categories == ["srt"]
    assert meta.total == 2
  end

  test "fetch_route_pipeline_log_distinct returns sorted level and category values" do
    assert {:ok, levels} =
             Analytics.fetch_route_pipeline_log_distinct("route-1", "level", FakeVictoriaLogs)

    assert levels == ["ERROR", "WARN"]

    assert {:ok, categories} =
             Analytics.fetch_route_pipeline_log_distinct("route-1", "category", FakeVictoriaLogs)

    assert categories == ["net", "srt"]
  end

  test "fetch_route_pipeline_log_distinct rejects invalid column" do
    assert {:error, {:bad_request, "Invalid column"}} =
             Analytics.fetch_route_pipeline_log_distinct("route-1", "message", FakeVictoriaLogs)
  end
end
