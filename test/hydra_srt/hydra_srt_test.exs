defmodule HydraSrtTest do
  use HydraSrt.DataCase, async: true

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
end
