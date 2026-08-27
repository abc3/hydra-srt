defmodule HydraSrt.RouteBackup do
  @moduledoc false

  import Ecto.Query, warn: false

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Api.Route
  alias HydraSrt.Db
  alias HydraSrt.Repo

  @backup_version "1.0"

  @route_fields ~w(
    name alias enabled node gstDebug tags
    backup_mode backup_switch_after_ms backup_cooldown_ms
    backup_primary_stable_ms backup_probe_interval_ms
  )

  @endpoint_fields ~w(
    enabled name alias node schema mode interface_sys_name localaddress localport
    address port host latency authentication streamid passphrase pbkeylen
    poll_timeout auto_reconnect keep_listening multicast multicast_iface
    bind_address_option path location allowed_list denied_list limit_access
    program_number
    ndi_source_name ndi_source_address ndi_selection_mode
    ndi_observed_address_snapshot ndi_observed_name_snapshot ndi_selection_observed_at
    ndi_receiver_name ndi_media_policy ndi_bandwidth ndi_color_format
    ndi_timestamp_mode ndi_connect_timeout_ms ndi_receive_timeout_ms
    ndi_track_discovery_timeout_ms ndi_max_queue_length ndi_sender_name
  )

  @type endpoint_field :: String.t()

  @spec export() :: {:ok, map()} | {:error, term()}
  def export do
    HydraSrt.BackupLock.run(&do_export/0)
  end

  @spec do_export() :: {:ok, map()} | {:error, term()}
  def do_export do
    with {:ok, routes} <- Db.get_all_routes(true) do
      {:ok,
       %{
         "backup_version" => @backup_version,
         "product_version" => product_version(),
         "routes" => Enum.map(routes, &export_route/1)
       }}
    end
  end

  @spec import(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import(backup) when is_map(backup) do
    HydraSrt.BackupLock.run(fn -> do_import(backup) end)
  end

  def import(_backup), do: {:error, :invalid_route_backup}

  @spec do_import(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def do_import(%{"backup_version" => @backup_version, "routes" => routes})
      when is_list(routes) and routes != [] do
    with :ok <- validate_routes(routes),
         :ok <- stop_routes() do
      case replace_routes_with_snapshot(routes) do
        {:ok, {count, previous_routes}} ->
          case start_enabled_routes() do
            :ok -> {:ok, count}
            {:error, reason} -> rollback_import(previous_routes, reason)
          end

        {:error, _reason} = error ->
          _ = start_enabled_routes()
          error
      end
    end
  end

  def do_import(%{"backup_version" => version}) when version != @backup_version do
    {:error, {:unsupported_backup_version, version}}
  end

  def do_import(_backup), do: {:error, :invalid_route_backup}

  @spec rollback_import([map()], term()) :: {:error, term()}
  def rollback_import(previous_routes, import_error) do
    with :ok <- stop_routes(),
         {:ok, _count} <- replace_routes(previous_routes),
         :ok <- start_enabled_routes() do
      {:error, import_error}
    else
      {:error, rollback_error} ->
        {:error, {:import_failed_and_rollback_failed, import_error, rollback_error}}
    end
  end

  @spec export_route(map()) :: map()
  def export_route(route) do
    route
    |> Map.take(@route_fields)
    |> Map.put("sources", Enum.map(route["sources"] || [], &export_source/1))
    |> Map.put(
      "destinations",
      route["destinations"]
      |> Kernel.||([])
      |> Enum.sort_by(& &1["position"])
      |> Enum.map(&export_endpoint/1)
    )
  end

  @spec export_source(map()) :: map()
  def export_source(source) do
    source
    |> export_endpoint()
    |> Map.put("position", source["position"])
  end

  @spec export_endpoint(%{optional(endpoint_field()) => term()}) :: %{endpoint_field() => term()}
  def export_endpoint(endpoint), do: Map.take(endpoint, @endpoint_fields)

  @spec validate_routes([map()]) :: :ok | {:error, atom()}
  def validate_routes(routes) do
    names = Enum.map(routes, &route_name/1)

    cond do
      Enum.any?(names, &is_nil/1) ->
        {:error, :route_name_required}

      length(names) != length(Enum.uniq(names)) ->
        {:error, :route_names_must_be_unique}

      Enum.any?(routes, fn route -> not valid_sources?(route["sources"]) end) ->
        {:error, :route_source_required}

      Enum.any?(routes, fn route -> not is_list(route["destinations"] || []) end) ->
        {:error, :invalid_destinations}

      true ->
        :ok
    end
  end

  @spec route_name(map()) :: binary() | nil
  def route_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def route_name(_route), do: nil

  @spec valid_sources?(term()) :: boolean()
  def valid_sources?(sources) when is_list(sources) and sources != [], do: true
  def valid_sources?(_sources), do: false

  @spec replace_routes([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def replace_routes(routes) do
    run_transaction(fn -> replace_routes!(routes) end)
  end

  @spec replace_routes_with_snapshot([map()]) ::
          {:ok, {non_neg_integer(), [map()]}} | {:error, term()}
  def replace_routes_with_snapshot(routes) do
    run_transaction(fn ->
      {:ok, %{"routes" => previous_routes}} = do_export()
      {replace_routes!(routes), previous_routes}
    end)
  end

  @spec run_transaction((-> result)) :: {:ok, result} | {:error, term()} when result: term()
  def run_transaction(operation) do
    Repo.transaction(operation)
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
    error -> {:error, error}
  end

  @spec replace_routes!([map()]) :: non_neg_integer()
  def replace_routes!(routes) do
    Repo.delete_all(Route)
    Enum.each(routes, &insert_route!/1)
    length(routes)
  end

  @spec insert_route!(map()) :: struct()
  def insert_route!(route_data) do
    {sources, route_data} = Map.pop(route_data, "sources")
    {destinations, route_data} = Map.pop(route_data, "destinations", [])
    {tag_names, route_data} = Map.pop(route_data, "tags", [])

    {:ok, tags} = Db.upsert_tags_by_name(Repo, tag_names)

    route =
      %Route{}
      |> Route.changeset(
        route_data
        |> Map.put("status", "stopped")
        |> Map.put("schema_status", nil)
      )
      |> Ecto.Changeset.put_assoc(:tags, tags)
      |> Repo.insert!()

    inserted_sources =
      sources
      |> Enum.with_index()
      |> Enum.map(fn {source, index} ->
        source
        |> Map.put("route_id", route.id)
        |> Map.put("position", index)
        |> Map.put("status", "stopped")
        |> then(&Endpoint.source_changeset(%Endpoint{}, &1))
        |> Repo.insert!()
      end)

    destinations
    |> Enum.with_index()
    |> Enum.each(fn {destination, index} ->
      destination
      |> Map.put("route_id", route.id)
      |> Map.put("position", index)
      |> Map.put("status", "stopped")
      |> then(&Endpoint.destination_changeset(%Endpoint{}, &1))
      |> Repo.insert!()
    end)

    primary_source = List.first(inserted_sources)

    from(r in Route, where: r.id == ^route.id)
    |> Repo.update_all(set: [active_source_id: primary_source.id])

    route
  end

  @spec stop_routes() :: :ok | {:error, term()}
  def stop_routes do
    with {:ok, routes} <- Db.get_all_routes(false) do
      routes
      |> Enum.reduce_while(:ok, fn %{"id" => route_id}, :ok ->
        case HydraSrt.stop_route(route_id) do
          :ok -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:route_stop_failed, route_id, reason}}}
        end
      end)
      |> case do
        :ok ->
          :ok

        {:error, _reason} = error ->
          _ = start_enabled_routes()
          error
      end
    end
  rescue
    error ->
      _ = start_enabled_routes()
      {:error, Exception.message(error)}
  end

  @spec start_enabled_routes() :: :ok | {:error, binary()}
  def start_enabled_routes do
    Enum.each(Db.list_enabled_routes(), fn route ->
      case HydraSrt.start_route(route.id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "failed to start route #{route.id}: #{inspect(reason)}"
      end
    end)

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec product_version() :: binary()
  def product_version do
    :hydra_srt
    |> Application.spec(:vsn)
    |> to_string()
  end
end
