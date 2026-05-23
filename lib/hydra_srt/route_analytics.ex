defmodule HydraSrt.RouteAnalytics do
  @moduledoc false

  alias HydraSrt.AnalyticsParams
  alias HydraSrt.Stats.Analytics

  @spec route_timeseries(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def route_timeseries(route_id, params)
      when is_binary(route_id) and is_map(params) do
    params = AnalyticsParams.normalize(params)

    with {:ok, query_params} <- Analytics.build_query_params(params) do
      Analytics.fetch_route_timeseries(route_id, query_params)
    end
  end

  @spec routes_status_timeseries(map()) :: {:ok, map()} | {:error, term()}
  def routes_status_timeseries(params) when is_map(params) do
    params = AnalyticsParams.normalize(params)

    with {:ok, query_params} <- Analytics.build_query_params(params) do
      Analytics.fetch_routes_status_timeseries(query_params)
    end
  end

  @spec routes_status_history(map()) :: {:ok, map()} | {:error, term()}
  def routes_status_history(params) when is_map(params) do
    params = AnalyticsParams.normalize(params)

    with {:ok, query_params} <- Analytics.build_query_params(params) do
      Analytics.fetch_routes_status_history(query_params, params)
    end
  end

  @spec route_events(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def route_events(route_id, params) when is_binary(route_id) and is_map(params) do
    Analytics.fetch_route_events(route_id, AnalyticsParams.normalize(params))
  end

  @spec route_pipeline_logs(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def route_pipeline_logs(route_id, params) when is_binary(route_id) and is_map(params) do
    Analytics.fetch_route_pipeline_logs(route_id, AnalyticsParams.normalize(params))
  end

  @spec route_pipeline_log_distinct(String.t(), String.t()) :: {:ok, [term()]} | {:error, term()}
  def route_pipeline_log_distinct(route_id, column)
      when is_binary(route_id) and is_binary(column) do
    Analytics.fetch_route_pipeline_log_distinct(route_id, column)
  end
end
