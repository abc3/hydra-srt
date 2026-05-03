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
        "backup_config" => %{"mode" => "passive"},
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

    attrs =
      attrs
      |> Enum.into(%{
        "position" => 0,
        "enabled" => true,
        "name" => "primary",
        "schema" => "UDP",
        "schema_options" => %{"host" => "127.0.0.1", "port" => 5000}
      })

    {:ok, source} = HydraSrt.Db.create_source(route_id, attrs)
    source
  end

  @doc """
  Generate a destination.
  """
  def destination_fixture(route, attrs \\ %{}) do
    route_id = if is_map(route), do: route["id"] || route.id, else: route

    attrs =
      attrs
      |> Enum.into(%{
        "alias" => "some alias",
        "enabled" => true,
        "name" => "some name",
        "schema" => "UDP",
        "schema_options" => %{"host" => "127.0.0.1", "port" => 5000},
        "started_at" => ~U[2025-02-19 16:24:00Z],
        "status" => "some status",
        "stopped_at" => ~U[2025-02-19 16:24:00Z]
      })

    {:ok, destination} = HydraSrt.Db.create_destination(route_id, attrs)

    destination
  end
end
