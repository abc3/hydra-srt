defmodule HydraSrtWeb.NodeController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Nodes

  def index(conn, _params) do
    json(conn, Nodes.list())
  end

  def show(conn, %{"id" => _node_name}) do
    json(conn, Nodes.self_stats())
  end

  def analytics(conn, %{"id" => node_id} = params) do
    case Nodes.analytics(node_id, params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to load node analytics: #{inspect(reason)}"})
    end
  end
end
