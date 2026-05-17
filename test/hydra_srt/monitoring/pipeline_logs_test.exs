defmodule HydraSrt.Monitoring.PipelineLogsTest do
  use ExUnit.Case, async: false

  alias HydraSrt.PipelineLogTelemetry

  setup do
    metrics_before = HydraSrt.PromEx.get_metrics()
    {:ok, metrics_before: metrics_before}
  end

  test "stored telemetry increments hydra_srt_pipeline_log_lines_total", %{metrics_before: before} do
    :ok = PipelineLogTelemetry.emit_stored("route-test-1", "WARN")

    after_metrics = HydraSrt.PromEx.get_metrics()

    assert metric_delta(before, after_metrics, "hydra_srt_pipeline_log_lines_total", [
             ~s(level="WARN"),
             ~s(route_id="route-test-1")
           ]) == 1
  end

  test "stored telemetry separates series by level and route_id", %{metrics_before: before} do
    :ok = PipelineLogTelemetry.emit_stored("route-test-2", "ERROR")

    after_metrics = HydraSrt.PromEx.get_metrics()

    assert metric_delta(before, after_metrics, "hydra_srt_pipeline_log_lines_total", [
             ~s(level="ERROR"),
             ~s(route_id="route-test-2")
           ]) == 1

    refute metric_line(before, "hydra_srt_pipeline_log_lines_total", [
             ~s(level="ERROR"),
             ~s(route_id="route-test-2")
           ])
  end

  test "dropped telemetry increments hydra_srt_pipeline_log_lines_dropped_total", %{
    metrics_before: before
  } do
    :ok = PipelineLogTelemetry.emit_dropped("route-test-3", "DEBUG")

    after_metrics = HydraSrt.PromEx.get_metrics()

    assert metric_delta(before, after_metrics, "hydra_srt_pipeline_log_lines_dropped_total", [
             ~s(level="DEBUG"),
             ~s(route_id="route-test-3")
           ]) == 1
  end

  test "unparsed telemetry increments hydra_srt_pipeline_log_lines_unparsed_total", %{
    metrics_before: before
  } do
    :ok = PipelineLogTelemetry.emit_unparsed("route-test-4")

    after_metrics = HydraSrt.PromEx.get_metrics()

    assert metric_delta(before, after_metrics, "hydra_srt_pipeline_log_lines_unparsed_total", [
             ~s(route_id="route-test-4")
           ]) == 1
  end

  defp metric_delta(before, after_metrics, metric_name, label_parts) do
    after_value = metric_value(after_metrics, metric_name, label_parts) || 0
    before_value = metric_value(before, metric_name, label_parts) || 0
    after_value - before_value
  end

  defp metric_line(metrics, metric_name, label_parts) do
    metrics
    |> String.split("\n")
    |> Enum.find(&(String.starts_with?(&1, metric_name) and labels_match?(&1, label_parts)))
  end

  defp metric_value(metrics, metric_name, label_parts) do
    case metric_line(metrics, metric_name, label_parts) do
      nil ->
        nil

      line ->
        case Regex.run(~r/\} (\d+(?:\.\d+)?)$/, line) do
          [_, value] -> parse_metric_number(value)
          _ -> nil
        end
    end
  end

  defp parse_metric_number(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        value |> String.to_float() |> trunc()
    end
  end

  defp labels_match?(line, label_parts) do
    Enum.all?(label_parts, &String.contains?(line, &1))
  end
end
