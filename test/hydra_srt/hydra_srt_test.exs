defmodule HydraSrtTest do
  use HydraSrt.DataCase, async: true

  import ExUnit.CaptureLog
  import HydraSrt.ApiFixtures
  alias HydraSrt.Db

  test "set_route_status/2 sets started_at and clears stopped_at when route starts" do
    route =
      route_fixture(%{
        status: "stopped",
        started_at: ~U[2025-02-18 14:51:00Z],
        stopped_at: ~U[2025-02-18 15:01:00Z]
      })

    before = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, updated} = HydraSrt.set_route_status(route.id, "started")

    after_ts = DateTime.utc_now() |> DateTime.truncate(:second)

    assert updated["status"] == "started"
    assert updated["stopped_at"] == nil
    assert DateTime.compare(updated["started_at"], before) in [:eq, :gt]
    assert DateTime.compare(updated["started_at"], after_ts) in [:eq, :lt]
  end

  test "mark_route_started/1 marks route as starting until native processing begins" do
    route =
      route_fixture(%{
        status: "stopped",
        schema_status: "stopped",
        stopped_at: ~U[2025-02-18 15:01:00Z]
      })

    destination_fixture(route, %{status: "stopped", enabled: true})

    before = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, updated} = HydraSrt.mark_route_started(route.id)

    after_ts = DateTime.utc_now() |> DateTime.truncate(:second)

    assert updated["status"] == "starting"
    assert updated["schema_status"] == "starting"
    assert updated["stopped_at"] == nil
    assert DateTime.compare(updated["started_at"], before) in [:eq, :gt]
    assert DateTime.compare(updated["started_at"], after_ts) in [:eq, :lt]

    assert {:ok, reloaded_route} = Db.get_route(route.id, true)

    assert [%{"enabled" => true, "status" => "starting"}] =
             Enum.map(reloaded_route["destinations"], &Map.take(&1, ["enabled", "status"]))
  end

  test "set_route_status/2 sets stopped_at and keeps started_at when route stops" do
    started_at = ~U[2025-02-18 14:51:00Z]

    route =
      route_fixture(%{
        status: "started",
        started_at: started_at,
        stopped_at: nil
      })

    before = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, updated} = HydraSrt.set_route_status(route.id, "stopped")

    after_ts = DateTime.utc_now() |> DateTime.truncate(:second)

    assert updated["status"] == "stopped"
    assert updated["started_at"] == started_at
    assert DateTime.compare(updated["stopped_at"], before) in [:eq, :gt]
    assert DateTime.compare(updated["stopped_at"], after_ts) in [:eq, :lt]
  end

  test "mark_route_stopped/1 sets schema status and stops only enabled destinations" do
    route =
      route_fixture(%{
        status: "started",
        schema_status: "starting",
        stopped_at: nil
      })

    destination_fixture(route, %{status: "starting", enabled: true})
    destination_fixture(route, %{status: "processing", enabled: false})

    assert {:ok, updated} = HydraSrt.mark_route_stopped(route.id)
    assert updated["status"] == "stopped"
    assert updated["schema_status"] == "stopped"

    assert {:ok, reloaded_route} = Db.get_route(route.id, true)

    assert reloaded_route["schema_status"] == "stopped"

    statuses_by_enabled =
      reloaded_route["destinations"]
      |> Enum.map(&{&1["enabled"], &1["status"]})

    assert {true, "stopped"} in statuses_by_enabled
    assert {false, "processing"} in statuses_by_enabled
  end

  test "startup recovery logs stale statuses and stops all routes and destinations" do
    route =
      route_fixture(%{
        enabled: false,
        status: "started",
        schema_status: "processing",
        stopped_at: nil
      })

    enabled_destination = destination_fixture(route, %{status: "starting", enabled: true})
    disabled_destination = destination_fixture(route, %{status: "processing", enabled: false})

    log =
      capture_log(fn ->
        assert :ok = HydraSrt.Application.recover_routes_after_startup()
      end)

    assert log =~ "found stale route status route_id=#{route.id}"
    assert log =~ "found stale destination status destination_id=#{enabled_destination.id}"
    assert log =~ "found stale destination status destination_id=#{disabled_destination.id}"

    assert {:ok, reloaded_route} = Db.get_route(route.id, true)
    assert reloaded_route["status"] == "stopped"
    assert reloaded_route["schema_status"] == "stopped"

    statuses_by_id =
      reloaded_route["destinations"]
      |> Map.new(&{&1["id"], &1["status"]})

    assert statuses_by_id[enabled_destination.id] == "stopped"
    assert statuses_by_id[disabled_destination.id] == "stopped"
  end
end
