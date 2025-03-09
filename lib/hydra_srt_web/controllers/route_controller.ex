defmodule HydraSrtWeb.RouteController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, _params) do
    with {:ok, routes} <- Db.get_all_routes() do
      data(conn, routes)
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch routes: #{inspect(error)}"})
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
    # :timer.sleep(1500)
    {:ok, route} = Db.get_route(id, true)
    data(conn, route)
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
        |> data(%{status: "started", route_id: route_id})

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

  defp data(conn, data), do: json(conn, %{data: data})
end
