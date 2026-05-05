defmodule HydraSrt.Db do
  @moduledoc false
  require Logger
  import Ecto.Query, warn: false

  alias HydraSrt.Repo
  alias HydraSrt.Api.Route
  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Api.Interface
  alias HydraSrt.Api.Tag
  alias HydraSrt.Stats.EventLogger

  @status_stopped "stopped"

  @spec create_route(map, binary | nil) :: {:ok, map} | {:error, any}
  def create_route(data, id \\ nil) when is_map(data) do
    {tag_names, route_data} = pop_tags(data)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:tags, fn repo, _changes ->
      upsert_tags_by_name(repo, tag_names || [])
    end)
    |> Ecto.Multi.insert(:route, fn %{tags: tags} ->
      %Route{}
      |> Route.changeset(route_data)
      |> maybe_put_changeset_id(id)
      |> Ecto.Changeset.put_assoc(:tags, tags)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{route: route}} ->
        # Preload sources for the map, route already has tags from put_assoc
        {:ok, route_to_map(Repo.preload(route, :sources))}

      {:error, :route, %Ecto.Changeset{} = changeset, _} ->
        {:error, changeset}

      {:error, :tags, reason, _} ->
        {:error, add_tags_error(%Route{}, route_data, reason)}

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  @spec get_route(String.t(), boolean) :: {:ok, map} | {:error, any}
  def get_route(id, include_dest? \\ false) when is_binary(id) do
    get_route(id, include_dest?, true)
  end

  @spec get_route_map(String.t(), boolean(), boolean()) :: map() | nil
  def get_route_map(id, include_dest? \\ false, include_sources? \\ true) when is_binary(id) do
    case get_route(id, include_dest?, include_sources?) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  @spec get_route(String.t(), boolean, boolean) :: {:ok, map} | {:error, any}
  def get_route(id, include_dest?, include_sources?) when is_binary(id) do
    case Repo.get(Route, id) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        route = Repo.preload(route, :tags)

        destinations =
          if include_dest? do
            list_destinations_for_route(id)
          else
            []
          end

        sources = if include_sources?, do: list_sources_for_route(id), else: []
        route_map = route_to_map(route, include_dest?, destinations, sources)

        {:ok, route_map}
    end
  end

  @spec update_route(String.t(), map) :: {:ok, map} | {:error, any}
  def update_route(id, data) when is_binary(id) and is_map(data) do
    case Repo.get(Route, id) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        {tag_names, route_data} = pop_tags(data)

        Ecto.Multi.new()
        |> Ecto.Multi.run(:tags, fn repo, _changes ->
          if is_list(tag_names) do
            upsert_tags_by_name(repo, tag_names)
          else
            {:ok, nil}
          end
        end)
        |> Ecto.Multi.update(:route, fn %{tags: tags} ->
          route
          |> Repo.preload(:tags)
          |> Route.changeset(route_data)
          |> then(fn cs ->
            if is_list(tag_names), do: Ecto.Changeset.put_assoc(cs, :tags, tags), else: cs
          end)
        end, stale_error_field: :lock_version)
        |> Repo.transaction()
        |> case do
          {:ok, %{route: updated}} ->
            # route_to_map needs sources; we preload them to avoid redundant get_route call
            {:ok, route_to_map(Repo.preload(updated, :sources))}

          {:error, :route, %Ecto.Changeset{} = changeset, _} ->
            {:error, changeset}

          {:error, :tags, reason, _} ->
            {:error, add_tags_error(route, route_data, reason)}

          {:error, _, reason, _} ->
            {:error, reason}
        end
    end
  end

  defp add_tags_error(route, route_data, reason) do
    route
    |> Route.changeset(route_data)
    |> Ecto.Changeset.add_error(:tags, to_string(reason))
  end

  @spec update_route_schema_status(String.t(), String.t() | nil) :: {:ok, map()} | {:error, any()}
  def update_route_schema_status(id, schema_status) when is_binary(id) do
    update_route(id, %{"schema_status" => schema_status})
  end

  @spec update_destinations_status(String.t(), String.t() | nil) :: :ok
  def update_destinations_status(route_id, status) when is_binary(route_id) do
    from(d in Endpoint,
      where:
        d.route_id == ^route_id and d.enabled == true and d.type == ^Endpoint.destination_type()
    )
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:microsecond)])

    :ok
  end

  @spec update_sources_status(String.t(), String.t() | nil, String.t() | nil) :: :ok
  def update_sources_status(route_id, status, active_source_id \\ nil) when is_binary(route_id) do
    now = DateTime.utc_now(:microsecond)

    active_source_id =
      if is_binary(active_source_id) do
        active_source_id
      else
        case Repo.get(Route, route_id) do
          %Route{} = route -> route.active_source_id
          _ -> nil
        end
      end

    # Sources are cold-standby. Only active source should mirror runtime status.
    from(s in Endpoint,
      where: s.route_id == ^route_id and s.type == ^Endpoint.source_type()
    )
    |> Repo.update_all(set: [status: "stopped", updated_at: now])

    if is_binary(active_source_id) do
      from(s in Endpoint,
        where:
          s.route_id == ^route_id and s.type == ^Endpoint.source_type() and
            s.id == ^active_source_id
      )
      |> Repo.update_all(set: [status: status, updated_at: now])
    end

    :ok
  end

  @spec list_routes_with_stale_runtime_status() :: list(%Route{})
  def list_routes_with_stale_runtime_status do
    from(r in Route, where: r.status != "stopped" or is_nil(r.status))
    |> Repo.all()
  end

  @spec list_destinations_with_stale_runtime_status() :: list(%Endpoint{})
  def list_destinations_with_stale_runtime_status do
    from(d in Endpoint,
      where:
        (d.status != "stopped" or is_nil(d.status)) and d.type == ^Endpoint.destination_type()
    )
    |> Repo.all()
  end

  @spec list_enabled_routes() :: list(%Route{})
  def list_enabled_routes do
    from(r in Route, where: r.enabled == true, order_by: [asc: r.inserted_at])
    |> Repo.all()
  end

  @spec list_all_tags() :: list(String.t())
  def list_all_tags do
    from(t in Tag, select: t.name, order_by: [asc: t.name])
    |> Repo.all()
  end

  @spec upsert_tags_by_name(list(String.t())) :: {:ok, list(%Tag{})} | {:error, any()}
  def upsert_tags_by_name(names) when is_list(names) do
    upsert_tags_by_name(Repo, names)
  end

  @spec upsert_tags_by_name(module(), list(String.t())) :: {:ok, list(%Tag{})} | {:error, any()}
  def upsert_tags_by_name(repo, names) when is_list(names) do
    names =
      names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if names == [] do
      {:ok, []}
    else
      now = DateTime.utc_now(:microsecond)

      rows =
        Enum.map(names, fn name ->
          %{
            id: Ecto.UUID.generate(),
            name: name,
            inserted_at: now,
            updated_at: now
          }
        end)

      repo.insert_all(Tag, rows, on_conflict: :nothing, conflict_target: [:name])

      tags =
        from(t in Tag, where: t.name in ^names)
        |> repo.all()

      if length(tags) == length(names) do
        {:ok, tags}
      else
        # This could happen if names are somehow invalid or if someone deleted a tag
        # between insert and select, but it's very unlikely.
        # We try to recover by returning what we found if it's acceptable.
        {:ok, tags}
      end
    end
  end

  @spec reset_runtime_statuses_to_stopped() :: %{
          routes: non_neg_integer(),
          destinations: non_neg_integer(),
          sources: non_neg_integer()
        }
  def reset_runtime_statuses_to_stopped do
    now = DateTime.utc_now(:microsecond)

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
      from(d in Endpoint, where: d.type == ^Endpoint.destination_type())
      |> Repo.update_all(
        set: [
          status: "stopped",
          stopped_at: now,
          updated_at: now
        ]
      )

    {sources_count, _} =
      from(s in Endpoint, where: s.type == ^Endpoint.source_type())
      |> Repo.update_all(
        set: [
          status: "stopped",
          stopped_at: now,
          updated_at: now
        ]
      )

    %{routes: routes_count, destinations: destinations_count, sources: sources_count}
  end

  @spec update_route_runtime_status(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, any()}
  def update_route_runtime_status(route_id, status) when is_binary(route_id) do
    :ok = update_destinations_status(route_id, status)
    :ok = update_sources_status(route_id, status)
    update_route_schema_status(route_id, status)
  end

  @spec transition_route_runtime_status(
          String.t(),
          map(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, map()} | {:error, any()}
  def transition_route_runtime_status(route_id, route_attrs, destinations_status, sources_status)
      when is_binary(route_id) and is_map(route_attrs) do
    case Repo.get(Route, route_id) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        case Repo.transaction(fn ->
               now = DateTime.utc_now(:microsecond)

               updated_route =
                 route
                 |> Route.changeset(route_attrs)
                 |> Repo.update(stale_error_field: :lock_version)
                 |> case do
                   {:ok, updated} -> updated
                   {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
                 end

               from(d in Endpoint,
                 where:
                   d.route_id == ^route_id and d.enabled == true and
                     d.type == ^Endpoint.destination_type()
               )
               |> Repo.update_all(set: [status: destinations_status, updated_at: now])

               from(s in Endpoint,
                 where: s.route_id == ^route_id and s.type == ^Endpoint.source_type()
               )
               |> Repo.update_all(set: [status: @status_stopped, updated_at: now])

               if is_binary(updated_route.active_source_id) do
                 from(s in Endpoint,
                   where:
                     s.route_id == ^route_id and s.type == ^Endpoint.source_type() and
                       s.id == ^updated_route.active_source_id
                 )
                 |> Repo.update_all(set: [status: sources_status, updated_at: now])
               end

               updated_route
             end) do
          {:ok, %Route{} = updated_route} ->
            {:ok, get_route_map(updated_route.id)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, changeset}
        end
    end
  end

  @spec delete_route(String.t()) :: [:ok] | [{:error, any}]
  def delete_route(id) when is_binary(id) do
    case Repo.get(Route, id) do
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
    data =
      data
      |> Map.put_new("route_id", route_id)
      |> ensure_destination_position_for_insert()

    changeset =
      %Endpoint{}
      |> Endpoint.destination_changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, destination} ->
        {:ok, destination_to_map(destination)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp ensure_destination_position_for_insert(data) when is_map(data) do
    if Map.has_key?(data, "position") or Map.has_key?(data, :position) do
      data
    else
      rid = Map.get(data, "route_id") || Map.get(data, :route_id)

      if is_binary(rid) do
        Map.put(data, "position", next_destination_position(rid))
      else
        data
      end
    end
  end

  defp next_destination_position(route_id) when is_binary(route_id) do
    from(e in Endpoint,
      where: e.route_id == ^route_id and e.type == ^Endpoint.destination_type(),
      select: max(e.position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      n when is_integer(n) -> n + 1
    end
  end

  @spec get_destination(String.t(), String.t()) :: {:ok, map} | {:error, any}
  def get_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    case get_endpoint_record(route_id, id, Endpoint.destination_type()) do
      nil -> {:error, :not_found}
      %Endpoint{} = destination -> {:ok, destination_to_map(destination)}
    end
  end

  @spec update_destination(String.t(), String.t(), map) :: {:ok, map} | {:error, any}
  def update_destination(route_id, id, data)
      when is_binary(route_id) and is_binary(id) and is_map(data) do
    case get_endpoint_record(route_id, id, Endpoint.destination_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = destination ->
        destination
        |> Endpoint.destination_changeset(data)
        |> Repo.update(stale_error_field: :lock_version)
        |> case do
          {:ok, updated} -> {:ok, destination_to_map(updated)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  def del_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    case get_endpoint_record(route_id, id, Endpoint.destination_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = destination ->
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
      |> Repo.preload(:tags)

    source_map = list_sources_for_routes(routes)

    destination_map =
      if with_destinations do
        list_destinations_for_routes(routes)
      else
        %{}
      end

    routes =
      Enum.map(routes, fn route ->
        sources = Map.get(source_map, route.id, [])
        destinations = Map.get(destination_map, route.id, [])
        route_to_map(route, with_destinations, destinations, sources)
      end)

    {:ok, routes}
  end

  def get_all_destinations(route_id) when is_binary(route_id) do
    {:ok, Enum.map(list_destinations_for_route(route_id), &destination_to_map/1)}
  end

  @spec create_source(String.t(), map, binary | nil) :: {:ok, map} | {:error, any}
  def create_source(route_id, data, id \\ nil)
      when is_binary(route_id) and is_map(data) do
    data = Map.put_new(data, "route_id", route_id)

    changeset =
      %Endpoint{}
      |> Endpoint.source_changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, source} ->
        {:ok, source_to_map(source)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec get_source(String.t(), String.t()) :: {:ok, map} | {:error, any}
  def get_source(route_id, id) when is_binary(route_id) and is_binary(id) do
    case get_endpoint_record(route_id, id, Endpoint.source_type()) do
      nil -> {:error, :not_found}
      %Endpoint{} = source -> {:ok, source_to_map(source)}
    end
  end

  @spec update_source(String.t(), String.t(), map) :: {:ok, map} | {:error, any}
  def update_source(route_id, id, data)
      when is_binary(route_id) and is_binary(id) and is_map(data) do
    case get_endpoint_record(route_id, id, Endpoint.source_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = source ->
        source
        |> Endpoint.source_changeset(data)
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, source_to_map(updated)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  def del_source(route_id, id) when is_binary(route_id) and is_binary(id) do
    route = Repo.get(Route, route_id)

    case get_endpoint_record(route_id, id, Endpoint.source_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = source ->
        if route && route.active_source_id == source.id do
          {:error, :active_source_cannot_be_deleted}
        else
          case Repo.delete(source) do
            {:ok, _} -> :ok
            {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
          end
        end
    end
  end

  def get_all_sources(route_id) when is_binary(route_id) do
    {:ok, Enum.map(list_sources_for_route(route_id), &source_to_map/1)}
  end

  @spec reorder_sources(String.t(), list(String.t())) :: {:ok, list(map())} | {:error, any()}
  def reorder_sources(route_id, source_ids)
      when is_binary(route_id) and is_list(source_ids) do
    sources = list_sources_for_route(route_id)
    existing_ids = MapSet.new(Enum.map(sources, & &1.id))
    requested_ids = MapSet.new(source_ids)

    cond do
      source_ids == [] ->
        {:error, :invalid_source_order}

      map_size(Map.new(Enum.with_index(source_ids))) != length(source_ids) ->
        {:error, :invalid_source_order}

      existing_ids != requested_ids ->
        {:error, :invalid_source_order}

      true ->
        case Repo.transaction(fn ->
               # Two-step update to avoid unique conflicts on (route_id, position).
               from(s in Endpoint,
                 where: s.route_id == ^route_id and s.type == ^Endpoint.source_type()
               )
               |> Repo.update_all(
                 inc: [position: 1000],
                 set: [updated_at: DateTime.utc_now(:microsecond)]
               )

               source_ids
               |> Enum.with_index()
               |> Enum.each(fn {id, position} ->
                 from(s in Endpoint,
                   where:
                     s.id == ^id and s.route_id == ^route_id and
                       s.type == ^Endpoint.source_type()
                 )
                 |> Repo.update_all(
                   set: [position: position, updated_at: DateTime.utc_now(:microsecond)]
                 )
               end)
             end) do
          {:ok, _} ->
            {:ok, Enum.map(list_sources_for_route(route_id), &source_to_map/1)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec set_route_active_source(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, any()}
  def set_route_active_source(route_id, source_id, reason)
      when is_binary(route_id) and is_binary(source_id) and is_binary(reason) do
    with %Route{} = route <- Repo.get(Route, route_id),
         %Endpoint{} = source <- get_endpoint_record(route_id, source_id, Endpoint.source_type()),
         {:ok, updated} <-
           route
           |> Route.changeset(%{
             "active_source_id" => source.id,
             "last_switch_reason" => reason,
             "last_switch_at" => DateTime.utc_now(:microsecond)
           })
           |> Repo.update() do
      map = get_route_map(updated.id)

      EventLogger.log_source_switch(
        route_id,
        route.active_source_id,
        source.id,
        reason,
        %{
          active_source_id: source.id
        }
      )

      Phoenix.PubSub.broadcast(
        HydraSrt.PubSub,
        "item:#{route_id}",
        {:item_source,
         %{
           item_id: route_id,
           active_source_id: source.id,
           last_switch_reason: reason,
           last_switch_at: map["last_switch_at"]
         }}
      )

      {:ok, map}
    else
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
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
    from(d in Endpoint,
      where: d.route_id == ^route_id and d.type == ^Endpoint.destination_type(),
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
  end

  @doc false
  def list_sources_for_route(route_id) when is_binary(route_id) do
    from(s in Endpoint,
      where: s.route_id == ^route_id and s.type == ^Endpoint.source_type(),
      order_by: [asc: s.position]
    )
    |> Repo.all()
  end

  defp list_sources_for_routes(routes) when is_list(routes) do
    route_ids = Enum.map(routes, & &1.id)

    from(s in Endpoint,
      where: s.route_id in ^route_ids and s.type == ^Endpoint.source_type(),
      order_by: [asc: s.position]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_id)
  end

  defp list_destinations_for_routes(routes) when is_list(routes) do
    route_ids = Enum.map(routes, & &1.id)

    from(d in Endpoint,
      where: d.route_id in ^route_ids and d.type == ^Endpoint.destination_type(),
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_id)
  end

  defp get_endpoint_record(route_id, endpoint_id, endpoint_type)
       when is_binary(route_id) and is_binary(endpoint_id) and is_binary(endpoint_type) do
    from(e in Endpoint,
      where: e.id == ^endpoint_id and e.route_id == ^route_id and e.type == ^endpoint_type
    )
    |> Repo.one()
  end

  @doc false
  def route_to_map(%Route{} = route, include_destinations \\ false) do
    route_to_map(route, include_destinations, [], list_sources_for_route(route.id))
  end

  @doc false
  def route_to_map(%Route{} = route, true, destinations, sources)
      when is_list(destinations) and is_list(sources) do
    Map.put(
      route_to_map(route, false, [], sources),
      "destinations",
      Enum.map(destinations, &destination_to_map/1)
    )
  end

  @doc false
  def route_to_map(%Route{} = route, false, _destinations, sources) when is_list(sources) do
    active_source =
      Enum.find(sources, &(&1.id == route.active_source_id)) ||
        Enum.find(sources, &(&1.position == 0))

    %{
      "id" => route.id,
      "enabled" => route.enabled,
      "name" => route.name,
      "alias" => route.alias,
      "status" => route.status,
      "schema_status" => route.schema_status,
      "sources" => Enum.map(sources, &source_to_map/1),
      "active_source_id" => route.active_source_id || (active_source && active_source.id),
      "backup_config" => route.backup_config || %{},
      "last_switch_reason" => route.last_switch_reason,
      "last_switch_at" => route.last_switch_at,
      "node" => route.node,
      "gstDebug" => route.gst_debug,
      "tags" =>
        case route.tags do
          %Ecto.Association.NotLoaded{} ->
            # Returning empty list is better than crashing, but we avoid side-effects here.
            []

          tags when is_list(tags) ->
            Enum.map(tags, & &1.name)
        end,
      "source" => route.source,
      "started_at" => route.started_at,
      "stopped_at" => route.stopped_at,
      "created_at" => route.inserted_at,
      "updated_at" => route.updated_at,
      "destinations" => []
    }
  end

  @doc false
  def destination_to_map(%Endpoint{} = destination) do
    endpoint_base_map(destination)
    |> Map.merge(%{
      "id" => destination.id,
      "route_id" => destination.route_id,
      "lock_version" => destination.lock_version,
      "alias" => destination.alias,
      "node" => destination.node,
      "started_at" => destination.started_at,
      "stopped_at" => destination.stopped_at
    })
  end

  @doc false
  def source_to_map(%Endpoint{} = source) do
    endpoint_base_map(source)
    |> Map.merge(%{
      "id" => source.id,
      "route_id" => source.route_id,
      "lock_version" => source.lock_version,
      "position" => source.position,
      "last_probe_at" => source.last_probe_at,
      "last_failure_at" => source.last_failure_at
    })
  end

  defp endpoint_base_map(%Endpoint{} = endpoint) do
    %{
      "enabled" => endpoint.enabled,
      "name" => endpoint.name,
      "schema" => endpoint.schema,
      "schema_options" => endpoint.schema_options,
      "status" => endpoint.status,
      "created_at" => endpoint.inserted_at,
      "updated_at" => endpoint.updated_at
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

  defp pop_tags(data) when is_map(data) do
    case Map.pop(data, "tags") do
      {nil, data} -> Map.pop(data, :tags)
      {tags, data} -> {tags, data}
    end
  end
end
