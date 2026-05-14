defmodule HydraSrtWeb.RouteController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db
  alias HydraSrt.SourceProbe
  alias HydraSrt.Stats.Analytics

  action_fallback HydraSrtWeb.FallbackController

  @default_page 1
  @default_limit 50
  @max_limit 500

  def index(conn, params) do
    page = parse_positive_int_or_default(Map.get(params, "page", @default_page), @default_page)

    limit =
      parse_positive_int_or_default(Map.get(params, "limit", @default_limit), @default_limit)

    sort_by = if Map.get(params, "sort_by") == "updated_at", do: "updated_at", else: "created_at"

    with {:ok, payload} <- Db.get_routes_page(true, sort_by, page, min(limit, @max_limit)) do
      conn
      |> json(%{
        data: payload.routes,
        meta: %{
          page: payload.page,
          limit: payload.limit,
          total: payload.total
        }
      })
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch routes: #{inspect(error)}"})
    end
  end

  def list_tags(conn, _params) do
    data(conn, Enum.map(Db.list_tags(), &serialize_tag/1))
  end

  def create_tag(conn, %{"tag" => tag_params}) do
    with {:ok, tag} <- Db.create_tag(tag_params) do
      conn
      |> put_status(:created)
      |> data(serialize_tag(tag))
    end
  end

  def update_tag(conn, %{"id" => id, "tag" => tag_params}) do
    with {:ok, tag} <- Db.update_tag(id, tag_params) do
      data(conn, serialize_tag(tag))
    end
  end

  def delete_tag(conn, %{"id" => id}) do
    with {:ok, _tag} <- Db.delete_tag(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def create(conn, %{"route" => route_params}) do
    with {:ok, route} <- Db.create_route(route_params) do
      conn
      |> put_status(:created)
      |> data(route)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, route} <- Db.get_route(id, true) do
      data(conn, route)
    end
  end

  def update(conn, %{"id" => id, "route" => route_params}) do
    with {:ok, route} <- Db.update_route(id, drop_runtime_status_fields(route_params)) do
      data(conn, route)
    end
  end

  def delete(conn, %{"id" => id}) do
    with [:ok, :ok] <- Db.delete_route(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def start(conn, %{"route_id" => route_id}) do
    case HydraSrt.start_route(route_id) do
      {:ok, _pid} ->
        conn
        |> put_status(:ok)
        |> data(%{status: "starting", route_id: route_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"route_id" => route_id}) do
    case HydraSrt.stop_route(route_id) do
      :ok ->
        conn
        |> put_status(:ok)
        |> data(%{status: "stopped", route_id: route_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def restart(conn, %{"route_id" => route_id}) do
    case HydraSrt.restart_route(route_id) do
      {:ok, _pid} ->
        conn
        |> put_status(:ok)
        |> data(%{status: "restarted", route_id: route_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def switch_source(conn, %{"id" => route_id, "source_id" => source_id}) do
    with {:ok, source} <- Db.get_source(route_id, source_id),
         true <- source["enabled"] == true or {:error, :source_disabled},
         {:ok, route} <- switch_route_source(route_id, source_id) do
      data(conn, route)
    end
  end

  def switch_source(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required 'source_id' parameter"})
  end

  def analytics(conn, %{"route_id" => route_id} = params) do
    with {:ok, query_params} <- Analytics.build_query_params(params),
         {:ok, analytics_data} <- Analytics.fetch_route_timeseries(route_id, query_params) do
      data(conn, analytics_data)
    else
      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch analytics"})
    end
  end

  def statuses_analytics(conn, params) do
    with {:ok, query_params} <- Analytics.build_query_params(params),
         {:ok, payload} <- Analytics.fetch_routes_status_timeseries(query_params) do
      data(conn, payload)
    else
      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch route status analytics"})
    end
  end

  def events(conn, %{"route_id" => route_id} = params) do
    with {:ok, payload} <- Analytics.fetch_route_events(route_id, params) do
      data(conn, payload)
    else
      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch events"})
    end
  end

  def test_source(conn, %{"route" => route_params}) do
    case SourceProbe.probe(route_params) do
      {:ok, result} ->
        conn
        |> put_status(:ok)
        |> data(result)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: client_probe_error(reason)})
    end
  end

  def test_source(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required 'route' parameter"})
  end

  defp data(conn, data), do: json(conn, %{data: data})

  defp serialize_tag(tag) do
    %{
      id: tag.id,
      name: tag.name,
      inserted_at: tag.inserted_at,
      updated_at: tag.updated_at
    }
  end

  defp client_probe_error(reason) do
    reason
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Failed to test source connection"
      message -> String.slice(message, 0, 500)
    end
  end

  defp parse_positive_int_or_default(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 ->
        parsed

      _ ->
        default
    end
  end

  defp parse_positive_int_or_default(value, _default) when is_integer(value) and value > 0,
    do: value

  defp parse_positive_int_or_default(_value, default), do: default

  defp switch_route_source(route_id, source_id) do
    case HydraSrt.get_route_handler(route_id) do
      {:ok, pid} ->
        case HydraSrt.RouteHandler.switch_source_sync(pid, source_id, "manual") do
          :ok -> Db.get_route(route_id, true)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        with {:ok, route} <- Db.get_route(route_id, true),
             true <- route_stopped?(route) or {:error, :route_handler_unavailable} do
          Db.set_route_active_source(route_id, source_id, "manual")
        end
    end
  end

  defp route_stopped?(route) when is_map(route) do
    status = Map.get(route, "status")
    status in [nil, "", "stopped", "failed"]
  end

  defp drop_runtime_status_fields(route_params) when is_map(route_params) do
    route_params
    |> Map.drop(["status", "schema_status"])
    |> Map.drop([:status, :schema_status])
  end
end
