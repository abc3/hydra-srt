defmodule HydraSrtWeb.NodeController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Monitoring.NodeStats

  def index(conn, _params) do
    json(conn, NodeStats.all_nodes())
  end

  def show(conn, %{"id" => _node_name}) do
    json(conn, NodeStats.self_node_stats())
  end
end
