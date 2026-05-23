defmodule HydraSrt.Nodes do
  @moduledoc false

  alias HydraSrt.AnalyticsParams
  alias HydraSrt.Monitoring.NodeStats
  alias HydraSrt.Stats.Analytics

  @spec list() :: [map()]
  def list, do: NodeStats.all_nodes()

  @spec self_stats() :: map()
  def self_stats, do: NodeStats.self_node_stats()

  @spec analytics(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def analytics(node_id, params) when is_binary(node_id) and is_map(params) do
    params = AnalyticsParams.normalize(params)

    with {:ok, query_params} <- Analytics.build_query_params(params) do
      Analytics.fetch_node_timeseries(node_id, query_params)
    end
  end
end
