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
        destinations: [],
        enabled: true,
        name: "some name",
        schema: "UDP",
        schema_options: %{},
        source: %{},
        started_at: ~U[2025-02-18 14:51:00Z],
        status: "some status",
        stopped_at: ~U[2025-02-18 14:51:00Z]
      })
      |> HydraSrt.Api.create_route()

    route
  end

  @doc """
  Generate a destination.
  """
  def destination_fixture(attrs \\ %{}) do
    {:ok, destination} =
      attrs
      |> Enum.into(%{
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

    destination
  end
end
