defmodule HydraSrt.DbFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `HydraSrt.Db` context.
  """

  @doc """
  Generate a route.
  """
  def route_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        "alias" => "some alias",
        "backup_mode" => "passive",
        "backup_switch_after_ms" => 3000,
        "backup_cooldown_ms" => 10000,
        "backup_primary_stable_ms" => 15000,
        "backup_probe_interval_ms" => 5000,
        "destinations" => [],
        "enabled" => true,
        "name" => "some name",
        "schema_status" => nil,
        "source" => %{},
        "started_at" => ~U[2025-02-18 14:51:00Z],
        "status" => "some status",
        "stopped_at" => ~U[2025-02-18 14:51:00Z]
      })

    {:ok, route} = HydraSrt.Db.create_route(attrs)

    route
  end

  @doc """
  Generate a source.
  """
  def source_fixture(route, attrs \\ %{}) do
    route_id = if is_map(route), do: route["id"] || route.id, else: route
    default_position = Map.get(attrs, "position") || Map.get(attrs, :position) || 0
    route_port_seed = abs(:erlang.phash2(route_id || "route")) |> rem(20_000)

    unique_port =
      10_000 + route_port_seed + default_position * 1000 +
        rem(System.unique_integer([:positive]), 1000)

    attrs =
      attrs
      |> Enum.into(%{
        "position" => default_position,
        "enabled" => true,
        "name" => "primary",
        "schema" => "UDP",
        "host" => "127.0.0.1",
        "port" => unique_port
      })

    {:ok, source} = HydraSrt.Db.create_source(route_id, attrs)
    source
  end

  @doc """
  Generate a destination.
  """
  def destination_fixture(route, attrs \\ %{}) do
    route_id = if is_map(route), do: route["id"] || route.id, else: route
    route_port_seed = abs(:erlang.phash2(route_id || "route")) |> rem(20_000)
    unique_port = 10_000 + route_port_seed + rem(System.unique_integer([:positive]), 1000)

    attrs =
      attrs
      |> Enum.into(%{
        "alias" => "some alias",
        "enabled" => true,
        "name" => "some name",
        "schema" => "UDP",
        "host" => "127.0.0.1",
        "port" => unique_port,
        "started_at" => ~U[2025-02-19 16:24:00Z],
        "status" => "some status",
        "stopped_at" => ~U[2025-02-19 16:24:00Z]
      })

    {:ok, destination} = HydraSrt.Db.create_destination(route_id, attrs)

    destination
  end
end
