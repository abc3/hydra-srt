defmodule HydraSrt.PromEx.Plugins.PipelineLogs do
  @moduledoc """
  Exposes parsed GStreamer pipeline log line metrics.
  """

  use PromEx.Plugin

  alias HydraSrt.PipelineLogTelemetry
  alias PromEx.MetricTypes.Event

  @prefix [:hydra_srt, :pipeline]

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :hydra_srt_pipeline_logs_event_metrics,
      [
        counter(
          @prefix ++ [:log_lines, :total],
          event_name: PipelineLogTelemetry.stored_event(),
          measurement: :count,
          description: "Pipeline log lines buffered for DuckDB storage.",
          tags: [:level, :route_id],
          tag_values: &stored_tags/1
        ),
        counter(
          @prefix ++ [:log_lines, :dropped, :total],
          event_name: PipelineLogTelemetry.dropped_event(),
          measurement: :count,
          description: "Verbose pipeline log lines dropped by rate limiting.",
          tags: [:level, :route_id],
          tag_values: &stored_tags/1
        ),
        counter(
          @prefix ++ [:log_lines, :unparsed, :total],
          event_name: PipelineLogTelemetry.unparsed_event(),
          measurement: :count,
          description: "Native pipeline stdout lines that failed GStreamer log parsing.",
          tags: [:route_id],
          tag_values: &unparsed_tags/1
        )
      ]
    )
  end

  defp stored_tags(metadata) do
    %{
      level: tag_string(Map.get(metadata, :level)),
      route_id: tag_string(Map.get(metadata, :route_id))
    }
  end

  defp unparsed_tags(metadata) do
    %{route_id: tag_string(Map.get(metadata, :route_id))}
  end

  defp tag_string(nil), do: "unknown"
  defp tag_string(value), do: to_string(value)
end
