defmodule HydraSrt.StatsHistory do
  @moduledoc false

  import Ecto.Query

  alias HydraSrt.Repo
  alias HydraSrt.RouteStat

  def insert_snapshot(route_id, source_stream_id, stats)
      when is_binary(route_id) and is_map(stats) do
    %RouteStat{}
    |> RouteStat.changeset(%{
      route_id: route_id,
      source_stream_id: source_stream_id,
      stats: stats
    })
    |> Repo.insert()
  end

  def prune_older_than_hours(hours) when is_integer(hours) and hours > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours, :hour)

    {deleted, _} =
      from(s in RouteStat, where: s.inserted_at < ^cutoff)
      |> Repo.delete_all()

    deleted
  end
end
