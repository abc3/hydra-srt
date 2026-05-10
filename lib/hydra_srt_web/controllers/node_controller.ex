defmodule HydraSrtWeb.NodeController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Monitoring.NodeStats
  alias HydraSrt.Stats.Analytics

  def index(conn, _params) do
    json(conn, NodeStats.all_nodes())
  end

  def show(conn, %{"id" => _node_name}) do
    json(conn, NodeStats.self_node_stats())
  end

  def analytics(conn, %{"id" => node_id} = params) do
    with {:ok, query_params} <- Analytics.build_query_params(params),
         {:ok, payload} <- Analytics.fetch_node_timeseries(node_id, query_params) do
      json(conn, payload)
    else
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
