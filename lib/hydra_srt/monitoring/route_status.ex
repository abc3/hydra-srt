defmodule HydraSrt.PromEx.Plugins.RouteStatus do
  @moduledoc """
  Exposes route runtime status transition metrics.
  """

  use PromEx.Plugin

  alias PromEx.MetricTypes.Event

  @prefix [:hydra_srt, :route, :status]
  @route_status_transition_event [:hydra, :route, :status, :transition]

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :hydra_srt_route_status_event_metrics,
      [
        counter(
          @prefix ++ [:transitions, :total],
          event_name: @route_status_transition_event,
          measurement: :count,
          description: "Total number of route runtime status transitions.",
          tags: [:from, :to],
          tag_values: &route_status_transition_tags/1
        )
      ]
    )
  end

  defp route_status_transition_tags(metadata) do
    %{
      from: to_string(Map.get(metadata, :from)),
      to: to_string(Map.get(metadata, :to))
    }
  end
end
