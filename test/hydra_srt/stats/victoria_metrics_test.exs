defmodule HydraSrt.Stats.VictoriaMetricsTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.Analytics
  alias HydraSrt.Stats.VictoriaMetrics

  test "row_to_prometheus_lines encodes stats sample labels and timestamp" do
    row = %{
      ts: ~U[2026-01-01 00:00:00Z],
      route_id: "route-1",
      entity_type: "destination",
      entity_id: "dest-1",
      metric_key: "srt_rtt_ms",
      value_type: "double",
      value_double: 18.5
    }

    assert [line] = VictoriaMetrics.row_to_prometheus_lines(row)
    assert line =~ "hydra_srt_stats_sample{"
    assert line =~ ~s(route_id="route-1")
    assert line =~ ~s(entity_type="destination")
    assert line =~ ~s(metric_key="srt_rtt_ms")
    assert line =~ " 18.5 1767225600000"
  end

  test "event_to_prometheus_lines encodes bounded event labels and status transition" do
    event = %{
      ts: ~U[2026-01-01 00:00:00Z],
      route_id: "route-1",
      event_type: "route_status_change",
      severity: "info",
      message: "Route status changed",
      details_json: Jason.encode!(%{"old_status" => "starting", "new_status" => "processing"})
    }

    assert [line] = VictoriaMetrics.event_to_prometheus_lines(event)
    assert line =~ "hydra_srt_route_event{"
    assert line =~ ~s(event_type="route_status_change")
    assert line =~ ~s(old_status="starting")
    assert line =~ ~s(new_status="processing")
    assert line =~ " 1 1767225600000"
  end

  test "event_to_prometheus_lines stores full details_json with escaped quotes and newlines" do
    details = %{
      "old_status" => "starting",
      "new_status" => "processing",
      "path" => ~s(srt://host:1234?streamid="live"),
      "note" => "line1\nline2"
    }

    event = %{
      ts: ~U[2026-01-01 00:00:00Z],
      route_id: "route-1",
      event_type: "route_status_change",
      details_json: Jason.encode!(details)
    }

    assert [line] = VictoriaMetrics.event_to_prometheus_lines(event)

    # The full JSON is stored under its own label with quotes/backslashes/newlines
    # escaped for the Prometheus line format, so the raw JSON quote and newline
    # never appear literally inside the label value.
    assert line =~ ~s(details_json=")
    # Backslash-escaped quote from the JSON string escaping of streamid="live".
    assert line =~ ~S(streamid=\\\")
    # Newline is escaped rather than emitted literally inside the single line.
    refute String.contains?(line, "\n")
    assert line =~ ~S(line1\\nline2)
    # old_status/new_status remain queryable as their own labels.
    assert line =~ ~s(old_status="starting")
    assert line =~ ~s(new_status="processing")
  end

  test "truncate_label leaves ASCII message under byte cap unchanged" do
    message = "Route status changed"
    assert VictoriaMetrics.truncate_label(message) == message
  end

  test "truncate_label bounds multi-byte UTF-8 message by bytes on valid boundary" do
    message = String.duplicate("é", 9000)
    assert byte_size(message) == 18_000

    result = VictoriaMetrics.truncate_label(message)

    assert byte_size(result) <= 16_000
    assert String.valid?(result)
    assert String.starts_with?(message, result)
  end

  test "truncate_label leaves exactly-at-cap UTF-8 message unchanged" do
    message = String.duplicate("é", 8000)
    assert byte_size(message) == 16_000
    assert VictoriaMetrics.truncate_label(message) == message
  end

  test "event_to_prometheus_lines truncates message at 16000 bytes" do
    long_message = String.duplicate("m", 20_000)

    event = %{
      ts: ~U[2026-01-01 00:00:00Z],
      route_id: "route-1",
      event_type: "publisher_rejected",
      message: long_message,
      details_json: Jason.encode!(%{"blob" => "small"})
    }

    assert VictoriaMetrics.truncate_label(long_message) |> byte_size() == 16_000
    assert [line] = VictoriaMetrics.event_to_prometheus_lines(event)
    refute line =~ String.duplicate("m", 16_001)
  end

  test "safe_details_label stores verbatim JSON under the cap" do
    details_json = Jason.encode!(%{"blob" => String.duplicate("d", 100)})

    assert VictoriaMetrics.safe_details_label(details_json) == details_json
  end

  test "safe_details_label emits a valid JSON marker when details_json exceeds the cap" do
    details_json = Jason.encode!(%{"blob" => String.duplicate("d", 20_000)})

    assert byte_size(details_json) > 16_000

    marker = VictoriaMetrics.safe_details_label(details_json)
    decoded = Jason.decode!(marker)

    assert decoded["_truncated"] == true
    assert decoded["bytes"] == byte_size(details_json)
    assert byte_size(marker) <= 16_000
  end

  test "event_to_prometheus_lines uses safe_details_label for oversized details_json" do
    details_json = Jason.encode!(%{"blob" => String.duplicate("d", 20_000)})

    event = %{
      ts: ~U[2026-01-01 00:00:00Z],
      route_id: "route-1",
      event_type: "publisher_rejected",
      details_json: details_json
    }

    assert [line] = VictoriaMetrics.event_to_prometheus_lines(event)
    labels = labels_from_event_prometheus_line(line)
    row = Analytics.event_row_from_labels(labels, VictoriaMetrics.row_ts_ms(event))

    assert Jason.decode!(row["details_json"])["_truncated"] == true
    assert Jason.decode!(row["details_json"])["bytes"] == byte_size(details_json)
  end

  test "details_json round-trips from prometheus labels through event_row_from_labels" do
    details = %{
      "old_status" => "starting",
      "new_status" => "processing",
      "path" => ~s(srt://host:1234?streamid="live"),
      "note" => "line1\nline2"
    }

    details_json = Jason.encode!(details)

    event = %{
      ts: ~U[2026-01-01 00:00:00Z],
      route_id: "route-1",
      event_type: "route_status_change",
      severity: "info",
      details_json: details_json
    }

    assert [line] = VictoriaMetrics.event_to_prometheus_lines(event)
    labels = labels_from_event_prometheus_line(line)
    row = Analytics.event_row_from_labels(labels, VictoriaMetrics.row_ts_ms(event))

    assert row["details_json"] == details_json
    assert Jason.decode!(row["details_json"]) == details
  end

  test "event_selector_for_route_ids builds a regex-escaped alternation matcher" do
    assert VictoriaMetrics.event_selector_for_route_ids(["route.1", "route-2"]) ==
             "hydra_srt_route_event{route_id=~\"^(route\\\\.1|route\\\\-2)$\"}"
  end

  test "event_selector_for_route_ids returns the bare metric for an empty set" do
    assert VictoriaMetrics.event_selector_for_route_ids([]) == "hydra_srt_route_event"
    assert VictoriaMetrics.event_selector_for_route_ids(["", nil]) == "hydra_srt_route_event"
  end

  test "selector escapes label values" do
    assert VictoriaMetrics.selector("metric", %{"route_id" => "route\"one"}) ==
             ~s(metric{route_id="route\\"one"})
  end

  test "selector builds an event_type match expression for server-side filtering" do
    assert VictoriaMetrics.selector(VictoriaMetrics.event_metric(), %{
             "event_type" => "route_status_change"
           }) ==
             ~s(hydra_srt_route_event{event_type="route_status_change"})

    assert VictoriaMetrics.selector(VictoriaMetrics.event_metric(), %{
             "route_id" => "route-1",
             "event_type" => "source_switch"
           }) ==
             ~s(hydra_srt_route_event{event_type="source_switch",route_id="route-1"})
  end

  defp labels_from_event_prometheus_line(line) when is_binary(line) do
    [metric_part | _] = String.split(line, " ", parts: 2)

    labels_str =
      case String.split(metric_part, "{", parts: 2) do
        [_, rest] -> String.trim_trailing(rest, "}")
        _ -> ""
      end

    ~r/(\w+)="((?:\\.|[^"\\])*)"/
    |> Regex.scan(labels_str)
    |> Map.new(fn [_full, key, value] -> {key, unescape_prometheus_label(value)} end)
  end

  defp unescape_prometheus_label(value) when is_binary(value) do
    placeholder = "\x00"

    value
    |> String.replace("\\\\", placeholder)
    |> String.replace("\\n", "\n")
    |> String.replace("\\\"", "\"")
    |> String.replace(placeholder, "\\")
  end
end
