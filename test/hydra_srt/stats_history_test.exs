defmodule HydraSrt.StatsHistoryTest do
  use HydraSrt.DataCase, async: false

  import Ecto.Query

  alias HydraSrt.Repo
  alias HydraSrt.RouteStat
  alias HydraSrt.StatsHistory

  test "insert_snapshot persists route_id, source_stream_id and stats" do
    route_id = "route_#{System.unique_integer([:positive])}"
    stats = %{"source" => %{"bytes_in_per_sec" => 1}}

    assert {:ok, %RouteStat{id: id}} =
             StatsHistory.insert_snapshot(route_id, "src-1", stats)

    assert %RouteStat{
             id: ^id,
             route_id: ^route_id,
             source_stream_id: "src-1",
             stats: ^stats
           } = Repo.get!(RouteStat, id)
  end

  test "insert_snapshot allows nil source_stream_id" do
    route_id = "route_#{System.unique_integer([:positive])}"
    stats = %{"ok" => true}

    assert {:ok, %RouteStat{source_stream_id: nil}} =
             StatsHistory.insert_snapshot(route_id, nil, stats)
  end

  test "prune_older_than_hours deletes only rows older than the window" do
    route_old = "route_old_#{System.unique_integer([:positive])}"
    route_new = "route_new_#{System.unique_integer([:positive])}"
    stats = %{"v" => 1}

    old_ts =
      DateTime.utc_now()
      |> DateTime.add(-48, :hour)
      |> DateTime.truncate(:second)

    new_ts =
      DateTime.utc_now()
      |> DateTime.add(-1, :hour)
      |> DateTime.truncate(:second)

    assert {:ok, _} =
             Repo.insert(%RouteStat{
               route_id: route_old,
               stats: stats,
               inserted_at: old_ts
             })

    assert {:ok, _} =
             Repo.insert(%RouteStat{
               route_id: route_new,
               stats: stats,
               inserted_at: new_ts
             })

    assert StatsHistory.prune_older_than_hours(24) == 1

    assert %RouteStat{route_id: ^route_new} =
             Repo.one!(from(r in RouteStat, where: r.route_id == ^route_new))

    assert Repo.one(from(r in RouteStat, where: r.route_id == ^route_old)) == nil
  end

  test "prune_older_than_hours returns zero when nothing is old enough" do
    route_id = "route_#{System.unique_integer([:positive])}"
    assert {:ok, _} = StatsHistory.insert_snapshot(route_id, nil, %{"x" => 1})

    assert StatsHistory.prune_older_than_hours(24) == 0
    assert Repo.one!(from(r in RouteStat, where: r.route_id == ^route_id))
  end
end
