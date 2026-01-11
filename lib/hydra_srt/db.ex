defmodule HydraSrt.Db do
  @moduledoc false
  require Logger
  import Ecto.Query, warn: false

  alias HydraSrt.Repo
  alias HydraSrt.Api
  alias HydraSrt.Api.Route
  alias HydraSrt.Api.Destination

  @spec create_route(map, binary | nil) :: {:ok, map} | {:error, any}
  def create_route(data, id \\ nil) when is_map(data) do
    changeset =
      %Route{}
      |> Route.changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, route} ->
        {:ok, route_to_map(route, false)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec get_route(String.t(), boolean) :: {:ok, map} | {:error, any}
  def get_route(id, include_dest? \\ false) when is_binary(id) do
    case Api.get_route(id, false) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        destinations =
          if include_dest? do
            list_destinations_for_route(id)
          else
            []
          end

        {:ok, route_to_map(route, include_dest?, destinations)}
    end
  end

  @spec update_route(String.t(), map) :: {:ok, map} | {:error, any}
  def update_route(id, data) when is_binary(id) and is_map(data) do
    case Api.get_route(id, false) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        route
        |> Route.changeset(data)
        |> Repo.update(stale_error_field: :lock_version)
        |> case do
          {:ok, updated} -> {:ok, route_to_map(updated, false)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @spec delete_route(String.t()) :: [:ok] | [{:error, any}]
  def delete_route(id) when is_binary(id) do
    case Api.get_route(id, false) do
      nil ->
        [{:error, :not_found}]

      %Route{} = route ->
        case Repo.delete(route) do
          {:ok, _} -> [:ok, :ok]
          {:error, %Ecto.Changeset{} = changeset} -> [{:error, changeset}]
        end
    end
  end

  @spec create_destination(String.t(), map, binary | nil) :: {:ok, map} | {:error, any}
  def create_destination(route_id, data, id \\ nil)
      when is_binary(route_id) and is_map(data) do
    data = Map.put_new(data, "route_id", route_id)

    changeset =
      %Destination{}
      |> Destination.changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, destination} ->
        {:ok, destination_to_map(destination)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec get_destination(String.t(), String.t()) :: {:ok, map} | {:error, any}
  def get_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    case Api.get_destination(route_id, id) do
      nil -> {:error, :not_found}
      %Destination{} = destination -> {:ok, destination_to_map(destination)}
    end
  end

  @spec update_destination(String.t(), String.t(), map) :: {:ok, map} | {:error, any}
  def update_destination(route_id, id, data)
      when is_binary(route_id) and is_binary(id) and is_map(data) do
    case Api.get_destination(route_id, id) do
      nil ->
        {:error, :not_found}

      %Destination{} = destination ->
        destination
        |> Destination.changeset(data)
        |> Repo.update(stale_error_field: :lock_version)
        |> case do
          {:ok, updated} -> {:ok, destination_to_map(updated)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  def del_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    case Api.get_destination(route_id, id) do
      nil ->
        {:error, :not_found}

      %Destination{} = destination ->
        case Repo.delete(destination) do
          {:ok, _} -> :ok
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @spec get_all_routes(boolean, binary) :: {:ok, list(map)} | {:error, any}
  def get_all_routes(with_destinations \\ false, sort_by \\ "created_at") do
    order_field =
      case sort_by do
        "updated_at" -> :updated_at
        _ -> :inserted_at
      end

    routes =
      from(r in Route, order_by: [desc: field(r, ^order_field)])
      |> Repo.all()

    routes =
      if with_destinations do
        Enum.map(routes, fn route ->
          destinations = list_destinations_for_route(route.id)
          route_to_map(route, true, destinations)
        end)
      else
        Enum.map(routes, &route_to_map(&1, false))
      end

    {:ok, routes}
  end

  def get_all_destinations(route_id) when is_binary(route_id) do
    {:ok, Enum.map(list_destinations_for_route(route_id), &destination_to_map/1)}
  end

  @spec backup() :: {:ok, binary} | {:error, any}
  def backup() do
    HydraSrt.Backup.backup_db_file()
  end

  @spec restore_backup(binary) :: :ok | {:error, any}
  def restore_backup(binary_data) when is_binary(binary_data) do
    HydraSrt.Backup.restore_db_file(binary_data)
  end

  @doc false
  def list_destinations_for_route(route_id) when is_binary(route_id) do
    from(d in Destination, where: d.route_id == ^route_id, order_by: [desc: d.inserted_at])
    |> Repo.all()
  end

  @doc false
  def route_to_map(%Route{} = route, include_destinations \\ false) do
    route_to_map(route, include_destinations, [])
  end

  @doc false
  def route_to_map(%Route{} = route, true, destinations) when is_list(destinations) do
    Map.put(
      route_to_map(route, false, []),
      "destinations",
      Enum.map(destinations, &destination_to_map/1)
    )
  end

  @doc false
  def route_to_map(%Route{} = route, false, _destinations) do
    %{
      "id" => route.id,
      "enabled" => route.enabled,
      "name" => route.name,
      "alias" => route.alias,
      "status" => route.status,
      "exportStats" => route.export_stats,
      "schema" => route.schema,
      "schema_options" => route.schema_options,
      "node" => route.node,
      "gstDebug" => route.gst_debug,
      "source" => route.source,
      "started_at" => route.started_at,
      "stopped_at" => route.stopped_at,
      "created_at" => route.inserted_at,
      "updated_at" => route.updated_at,
      "destinations" => []
    }
  end

  @doc false
  def destination_to_map(%Destination{} = destination) do
    %{
      "id" => destination.id,
      "route_id" => destination.route_id,
      "enabled" => destination.enabled,
      "name" => destination.name,
      "alias" => destination.alias,
      "status" => destination.status,
      "schema" => destination.schema,
      "schema_options" => destination.schema_options,
      "node" => destination.node,
      "started_at" => destination.started_at,
      "stopped_at" => destination.stopped_at,
      "created_at" => destination.inserted_at,
      "updated_at" => destination.updated_at
    }
  end

  @doc false
  def maybe_put_changeset_id(%Ecto.Changeset{} = changeset, nil), do: changeset

  @doc false
  def maybe_put_changeset_id(%Ecto.Changeset{} = changeset, id) when is_binary(id) do
    Ecto.Changeset.put_change(changeset, :id, id)
  end
end
