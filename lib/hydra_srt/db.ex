defmodule HydraSrt.Db do
  @moduledoc false
  require Logger
  import Ecto.Query, warn: false

  alias HydraSrt.Repo
  alias HydraSrt.Api
  alias HydraSrt.Api.Route
  alias HydraSrt.Api.Destination
  alias HydraSrt.Api.Interface

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

        route_map =
          route_to_map(route, include_dest?, destinations)

        {:ok, route_map}
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

  @spec update_route_schema_status(String.t(), String.t() | nil) :: {:ok, map()} | {:error, any()}
  def update_route_schema_status(id, schema_status) when is_binary(id) do
    update_route(id, %{"schema_status" => schema_status})
  end

  @spec update_destinations_status(String.t(), String.t() | nil) :: :ok
  def update_destinations_status(route_id, status) when is_binary(route_id) do
    from(d in Destination, where: d.route_id == ^route_id and d.enabled == true)
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:second)])

    :ok
  end

  @spec list_routes_with_stale_runtime_status() :: list(%Route{})
  def list_routes_with_stale_runtime_status do
    from(r in Route, where: r.status != "stopped" or is_nil(r.status))
    |> Repo.all()
  end

  @spec list_destinations_with_stale_runtime_status() :: list(%Destination{})
  def list_destinations_with_stale_runtime_status do
    from(d in Destination, where: d.status != "stopped" or is_nil(d.status))
    |> Repo.all()
  end

  @spec list_enabled_routes() :: list(%Route{})
  def list_enabled_routes do
    from(r in Route, where: r.enabled == true, order_by: [asc: r.inserted_at])
    |> Repo.all()
  end

  @spec reset_runtime_statuses_to_stopped() :: %{
          routes: non_neg_integer(),
          destinations: non_neg_integer()
        }
  def reset_runtime_statuses_to_stopped do
    now = DateTime.utc_now(:second)

    {routes_count, _} =
      from(r in Route)
      |> Repo.update_all(
        set: [
          status: "stopped",
          schema_status: "stopped",
          stopped_at: now,
          updated_at: now
        ]
      )

    {destinations_count, _} =
      from(d in Destination)
      |> Repo.update_all(
        set: [
          status: "stopped",
          stopped_at: now,
          updated_at: now
        ]
      )

    %{routes: routes_count, destinations: destinations_count}
  end

  @spec update_route_runtime_status(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, any()}
  def update_route_runtime_status(route_id, status) when is_binary(route_id) do
    :ok = update_destinations_status(route_id, status)
    update_route_schema_status(route_id, status)
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

  @spec create_interface(map(), binary() | nil) :: {:ok, map()} | {:error, any()}
  def create_interface(data, id \\ nil) when is_map(data) do
    changeset =
      %Interface{}
      |> Interface.changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, interface} ->
        {:ok, interface_to_map(interface)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec get_interface(String.t()) :: {:ok, map()} | {:error, any()}
  def get_interface(id) when is_binary(id) do
    case Repo.get(Interface, id) do
      nil -> {:error, :not_found}
      %Interface{} = interface -> {:ok, interface_to_map(interface)}
    end
  end

  @spec get_interface_by_sys_name(String.t()) :: {:ok, map()} | {:error, any()}
  def get_interface_by_sys_name(sys_name) when is_binary(sys_name) do
    case Repo.get_by(Interface, sys_name: sys_name) do
      nil -> {:error, :not_found}
      %Interface{} = interface -> {:ok, interface_to_map(interface)}
    end
  end

  @spec update_interface(String.t(), map()) :: {:ok, map()} | {:error, any()}
  def update_interface(id, data) when is_binary(id) and is_map(data) do
    case Repo.get(Interface, id) do
      nil ->
        {:error, :not_found}

      %Interface{} = interface ->
        interface
        |> Interface.changeset(data)
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, interface_to_map(updated)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @spec delete_interface(String.t()) :: :ok | {:error, any()}
  def delete_interface(id) when is_binary(id) do
    case Repo.get(Interface, id) do
      nil ->
        {:error, :not_found}

      %Interface{} = interface ->
        case Repo.delete(interface) do
          {:ok, _} -> :ok
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @spec get_all_interfaces() :: {:ok, list(map())}
  def get_all_interfaces() do
    interfaces =
      from(i in Interface, order_by: [desc: i.inserted_at])
      |> Repo.all()
      |> Enum.map(&interface_to_map/1)

    {:ok, interfaces}
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
      "schema_status" => route.schema_status,
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
  def interface_to_map(%Interface{} = interface) do
    %{
      "id" => interface.id,
      "name" => interface.name,
      "sys_name" => interface.sys_name,
      "ip" => interface.ip,
      "enabled" => interface.enabled,
      "created_at" => interface.inserted_at,
      "updated_at" => interface.updated_at
    }
  end

  @doc false
  def maybe_put_changeset_id(%Ecto.Changeset{} = changeset, nil), do: changeset

  @doc false
  def maybe_put_changeset_id(%Ecto.Changeset{} = changeset, id) when is_binary(id) do
    Ecto.Changeset.put_change(changeset, :id, id)
  end
end
