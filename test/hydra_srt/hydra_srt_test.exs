defmodule HydraSrtTest do
  use HydraSrt.DataCase, async: true

  import HydraSrt.ApiFixtures

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
end
