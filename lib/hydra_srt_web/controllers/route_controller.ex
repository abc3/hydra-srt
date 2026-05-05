defmodule HydraSrtWeb.RouteController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db
  alias HydraSrt.SourceProbe
  alias HydraSrt.Stats.Analytics

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, _params) do
    with {:ok, routes} <- Db.get_all_routes(true) do
      data(conn, routes)
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch routes: #{inspect(error)}"})
    end
  end

  def list_tags(conn, _params) do
    data(conn, Db.list_all_tags())
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
    with {:ok, route} <- Db.update_route(id, route_params) do
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

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch analytics: #{inspect(reason)}"})
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

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch events: #{inspect(reason)}"})
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

  defp client_probe_error(reason) do
    reason
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Failed to test source connection"
      message -> String.slice(message, 0, 500)
    end
  end

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
end
