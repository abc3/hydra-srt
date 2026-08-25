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
        backup_mode: "passive",
        backup_switch_after_ms: 3000,
        backup_cooldown_ms: 10_000,
        backup_primary_stable_ms: 15_000,
        backup_probe_interval_ms: 5000,
        enabled: true,
        name: "some name",
        schema_status: nil,
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

    unique_port = 10_000 + rem(System.unique_integer([:positive]), 50_000)

    {:ok, destination} =
      attrs
      |> Enum.into(%{
        route_id: route_id,
        alias: "some alias",
        enabled: true,
        name: "some name",
        schema: "UDP",
        host: "127.0.0.1",
        port: unique_port,
        started_at: ~U[2025-02-19 16:24:00Z],
        status: "some status",
        stopped_at: ~U[2025-02-19 16:24:00Z]
      })
      |> HydraSrt.Api.create_destination()

    HydraSrt.Api.get_destination!(destination.id)
  end

  @doc """
  Generate a source for a given route.
  """
  def source_fixture(route, attrs \\ %{}) do
    route_id =
      cond do
        is_binary(route) -> route
        is_map(route) -> Map.get(route, :id) || Map.get(route, "id")
        true -> nil
      end

    default_position = Map.get(attrs, :position) || Map.get(attrs, "position") || 0
    route_port_seed = abs(:erlang.phash2(route_id || "route")) |> rem(20_000)

    {:ok, source} =
      attrs
      |> Enum.into(%{
        route_id: route_id,
        position: default_position,
        enabled: true,
        name: "primary",
        schema: "UDP",
        host: "127.0.0.1",
        port: 5000 + default_position + route_port_seed
      })
      |> HydraSrt.Api.create_source()

    HydraSrt.Api.get_source!(source.id)
  end

  @doc """
  Generate a interface.
  """
  def interface_fixture(attrs \\ %{}) do
    {:ok, interface} =
      attrs
      |> Enum.into(%{
        enabled: true,
        ip: "some ip",
        name: "some name",
        sys_name: "some sys_name"
      })
      |> HydraSrt.Api.create_interface()

    interface
  end
end
