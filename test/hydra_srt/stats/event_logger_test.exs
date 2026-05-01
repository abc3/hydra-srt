defmodule HydraSrt.Stats.EventLoggerTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.EventLogger

  test "flush_events preserves insertion order" do
    events = [
      %{route_id: "route-1", event_type: "pipeline_reconnecting", ts: ~U[2026-01-01 00:00:01Z]},
      %{route_id: "route-1", event_type: "pipeline_failed", ts: ~U[2026-01-01 00:00:02Z]}
    ]

    assert {[], :ok} =
             EventLogger.flush_events(Enum.reverse(events), fn rows ->
               send(self(), {:inserted_rows, rows})
               :ok
             end)

    assert_receive {:inserted_rows, inserted}
    assert Enum.map(inserted, & &1.event_type) == ["pipeline_reconnecting", "pipeline_failed"]
  end

  test "flush_events keeps events when insert fails" do
    events = [%{route_id: "route-1", event_type: "pipeline_failed", ts: ~U[2026-01-01 00:00:01Z]}]

    assert {^events, {:error, :duckdb_down}} =
             EventLogger.flush_events(events, fn _rows -> {:error, :duckdb_down} end)
  end

  test "broadcast_event publishes to route-specific topic" do
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:route-1")

    :ok =
      EventLogger.broadcast_event(%{
        route_id: "route-1",
        event_type: "source_switch",
        ts: ~U[2026-01-01 00:00:01Z]
      })

    assert_receive {:event, %{"route_id" => "route-1", "event_type" => "source_switch"}}
  end
end
