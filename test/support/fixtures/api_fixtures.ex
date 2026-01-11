defmodule HydraSrt.ApiFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `HydraSrt.Api` context.
  """

  @doc """
  Generate a route.
  """
  def route_fixture(attrs \\ %{}) do
    {:ok, route} =
      attrs
      |> Enum.into(%{
        alias: "some alias",
        enabled: true,
        name: "some name",
        exportStats: false,
        schema: "UDP",
        schema_options: %{},
        source: %{},
        started_at: ~U[2025-02-18 14:51:00Z],
        status: "some status",
        stopped_at: ~U[2025-02-18 14:51:00Z]
      })
      |> HydraSrt.Api.create_route()

    HydraSrt.Api.get_route!(route.id)
  end

  @doc """
  Generate a destination.
  """
  def destination_fixture(arg \\ %{})

  def destination_fixture(%HydraSrt.Api.Route{} = route), do: destination_fixture(route, %{})

  def destination_fixture(route_id) when is_binary(route_id),
    do: destination_fixture(route_id, %{})

  def destination_fixture(attrs) when is_map(attrs) do
    route = route_fixture()
    destination_fixture(route, attrs)
  end

  @doc """
  Generate a destination for a given route.
  """
  def destination_fixture(route, attrs) do
    route_id =
      cond do
        is_binary(route) -> route
        is_map(route) -> Map.get(route, :id) || Map.get(route, "id")
        true -> nil
      end

    {:ok, destination} =
      attrs
      |> Enum.into(%{
        route_id: route_id,
        alias: "some alias",
        enabled: true,
        name: "some name",
        schema: "UDP",
        schema_options: %{host: "127.0.0.1", port: 5000},
        started_at: ~U[2025-02-19 16:24:00Z],
        status: "some status",
        stopped_at: ~U[2025-02-19 16:24:00Z]
      })
      |> HydraSrt.Api.create_destination()

    HydraSrt.Api.get_destination!(destination.id)
  end
end
