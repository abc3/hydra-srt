defmodule HydraSrt.StatsRetentionTest do
  use HydraSrt.DataCase, async: false

  import Ecto.Query

  alias HydraSrt.Repo
  alias HydraSrt.RouteStat

  test "StatsRetention is registered and prune message deletes stale rows" do
    pid = Process.whereis(HydraSrt.StatsRetention)
    assert is_pid(pid)

    Ecto.Adapters.SQL.Sandbox.allow(HydraSrt.Repo, self(), pid)

    route_id = "route_stale_#{System.unique_integer([:positive])}"

    old_ts =
      DateTime.utc_now()
      |> DateTime.add(-48, :hour)
      |> DateTime.truncate(:second)

    assert {:ok, _} =
             Repo.insert(%RouteStat{
               route_id: route_id,
               stats: %{},
               inserted_at: old_ts
             })

    send(pid, :prune)
    Process.sleep(100)

    assert Repo.one(from(r in RouteStat, where: r.route_id == ^route_id)) == nil
  end
end
