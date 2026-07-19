defmodule HydraSrt.EndpointHealthTest do
  use HydraSrt.DataCase, async: false

  import HydraSrt.ApiFixtures

  alias HydraSrt.Api
  alias HydraSrt.EndpointHealth
  alias HydraSrt.RouteHandler

  test "stopped snapshot derives stopped/disabled records and never healthy state" do
    route = route_fixture()

    {:ok, source} =
      Api.create_source(route.id, %{
        position: 0,
        schema: "NDI",
        enabled: true,
        name: "ndi-src",
        ndi_selection_mode: "discovery_name",
        ndi_source_name: "CAM (A)"
      })

    {:ok, dest} =
      Api.create_destination(route.id, %{
        schema: "NDI",
        enabled: false,
        name: "ndi-dest",
        ndi_sender_name: "Hydra Out #{System.unique_integer([:positive])}"
      })

    now = ~U[2026-07-19 12:00:00Z]

    assert {:ok, snapshot} =
             EndpointHealth.snapshot(route.id,
               lookup_fun: fn _ -> {:error, :not_found} end,
               now: now
             )

    assert snapshot.generated_at == "2026-07-19T12:00:00Z"
    assert snapshot.config_revision == nil
    assert snapshot.process_instance_id == nil
    assert snapshot.last_sequence == 0

    by_id = Map.new(snapshot.endpoints, &{&1["endpoint_id"], &1})
    assert by_id[source.id]["state"] == "stopped"
    assert by_id[source.id]["direction"] == "source"
    assert by_id[source.id]["transport"] == "ndi"
    assert by_id[dest.id]["state"] == "disabled"
    assert by_id[dest.id]["direction"] == "destination"

    refute Enum.any?(snapshot.endpoints, fn record ->
             record["state"] in ["streaming", "advertising", "connecting"]
           end)
  end

  test "live snapshot merges handler health identity per saved NDI endpoint" do
    route = route_fixture()

    {:ok, source} =
      Api.create_source(route.id, %{
        position: 0,
        schema: "NDI",
        enabled: true,
        name: "ndi-src",
        ndi_selection_mode: "discovery_name",
        ndi_source_name: "CAM (A)"
      })

    {:ok, _dest} =
      Api.create_destination(route.id, %{
        schema: "NDI",
        enabled: true,
        name: "ndi-dest",
        ndi_sender_name: "Hydra Out #{System.unique_integer([:positive])}"
      })

    identity = %{
      process_instance_id: "piid-live",
      config_revision: "rev-9",
      last_sequence: 7,
      endpoint_health: %{
        source.id => %{
          "endpoint_id" => source.id,
          "state" => "streaming",
          "sequence" => 7,
          "config_revision" => "rev-9",
          "process_instance_id" => "piid-live"
        }
      }
    }

    now = ~U[2026-07-19 12:30:00Z]

    assert {:ok, snapshot} =
             EndpointHealth.snapshot(route.id,
               lookup_fun: fn _ -> {:ok, self()} end,
               health_fun: fn _pid -> {:ok, identity} end,
               now: now
             )

    assert snapshot.process_instance_id == "piid-live"
    assert snapshot.config_revision == "rev-9"
    assert snapshot.last_sequence == 7

    by_id = Map.new(snapshot.endpoints, &{&1["endpoint_id"], &1})
    assert by_id[source.id]["state"] == "streaming"
    assert length(snapshot.endpoints) == 2

    other_id =
      hd(Enum.reject(snapshot.endpoints, &(&1["endpoint_id"] == source.id)))["endpoint_id"]

    assert by_id[other_id]["state"] == "unknown"
  end

  test "RouteHandler.endpoint_health_identity derives revision and sequence" do
    data = %{
      id: "route-1",
      process_instance_id: "piid-1",
      endpoint_health: %{
        "ep-a" => %{"sequence" => 2, "config_revision" => "rev-a"},
        "ep-b" => %{"sequence" => 5, "config_revision" => "rev-a"}
      }
    }

    identity = RouteHandler.endpoint_health_identity(data)
    assert identity.process_instance_id == "piid-1"
    assert identity.config_revision == "rev-a"
    assert identity.last_sequence == 5
  end
end
