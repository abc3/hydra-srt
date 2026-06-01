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
    default_schema = Map.get(attrs, "schema") || Map.get(attrs, :schema) || "UDP"
    unique_port = endpoint_free_port(default_schema, default_position)

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
    schema = Map.get(attrs, "schema") || Map.get(attrs, :schema) || "UDP"
    unique_port = endpoint_free_port(schema, 0)

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

    create_destination_with_retry(route_id, attrs, 5)
  end

  def endpoint_free_port(schema, _position) when schema in ["SRT"] do
    HydraSrt.TestSupport.E2EHelpers.tcp_free_port!()
  end

  def endpoint_free_port(_schema, _position) do
    HydraSrt.TestSupport.E2EHelpers.udp_free_port!()
  end

  def create_destination_with_retry(route_id, attrs, attempts_left) do
    case HydraSrt.Db.create_destination(route_id, attrs) do
      {:ok, destination} ->
        destination

      {:error, %Ecto.Changeset{errors: errors}}
      when attempts_left > 0 and is_list(errors) ->
        if Keyword.has_key?(errors, :bind_port) do
          schema = Map.get(attrs, "schema") || Map.get(attrs, :schema) || "UDP"
          retry_attrs = Map.put(attrs, "port", endpoint_free_port(schema, 0))
          create_destination_with_retry(route_id, retry_attrs, attempts_left - 1)
        else
          raise "destination_fixture failed: #{inspect(errors)}"
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        raise "destination_fixture failed: #{inspect(changeset.errors)}"
    end
  end
end
