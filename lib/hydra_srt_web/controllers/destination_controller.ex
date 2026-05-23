defmodule HydraSrtWeb.DestinationController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Destinations

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, %{"route_id" => route_id}) do
    with {:ok, destinations} <- Destinations.list(route_id) do
      data(conn, destinations)
    end
  end

  def create(conn, %{"destination" => dest_params, "route_id" => route_id}) do
    with {:ok, route} <- Destinations.create(route_id, dest_params) do
      conn
      |> put_status(:created)
      |> data(route)
    end
  end

  def show(conn, %{"dest_id" => id, "route_id" => route_id}) do
    with {:ok, route} <- Destinations.get(route_id, id) do
      data(conn, route)
    end
  end

  def update(conn, %{"dest_id" => id, "route_id" => route_id, "destination" => dest_params}) do
    with {:ok, route} <- Destinations.update(route_id, id, dest_params) do
      data(conn, route)
    end
  end

  def delete(conn, %{"dest_id" => id, "route_id" => route_id}) do
    with :ok <- Destinations.delete(route_id, id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp data(conn, data), do: json(conn, %{data: data})
end
