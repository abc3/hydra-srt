defmodule HydraSrt.Mcp.Tools.Logs do
  @moduledoc false

  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Mcp.Tools.Routes, as: Schema
  alias HydraSrt.RouteAnalytics

  @window_description """
  Time range: window one of last_30_min, last_hour, last_6_hour, last_24_hour, or custom from+to ISO8601. \
  Do not use window live; send explicit from/to for polling.
  """

  @spec definitions() :: [map()]
  def definitions do
    route_id = Schema.string_prop("Route ID")

    time_props = %{
      "window" => Schema.string_prop("Preset window"),
      "from" => Schema.string_prop("Custom range start ISO8601"),
      "to" => Schema.string_prop("Custom range end ISO8601")
    }

    [
      %{
        name: "get_route_events",
        description: "Route event log. #{@window_description}",
        input_schema:
          Schema.object_schema(
            Map.merge(time_props, %{
              "route_id" => route_id,
              "limit" => Schema.integer_prop("Page size"),
              "offset" => Schema.integer_prop("Offset"),
              "type" => Schema.string_prop("Event type filter")
            }),
            ["route_id"]
          )
      },
      %{
        name: "get_route_pipeline_logs",
        description: "GStreamer pipeline logs for a route. #{@window_description}",
        input_schema:
          Schema.object_schema(
            Map.merge(time_props, %{
              "route_id" => route_id,
              "limit" => Schema.integer_prop("Page size"),
              "offset" => Schema.integer_prop("Offset"),
              "levels" => Schema.string_prop("Comma-separated level filters"),
              "categories" => Schema.string_prop("Comma-separated category filters")
            }),
            ["route_id"]
          )
      },
      %{
        name: "get_route_pipeline_log_distinct",
        description: "Distinct pipeline log values for a column (level or category).",
        input_schema:
          Schema.object_schema(
            %{
              "route_id" => route_id,
              "column" => Schema.enum_prop(["level", "category"], "Column name")
            },
            ["route_id", "column"]
          )
      },
      %{
        name: "get_routes_status_history",
        description: "Route status change history. #{@window_description}",
        input_schema:
          Schema.object_schema(
            Map.merge(time_props, %{
              "route_id" => Schema.string_prop("Optional route filter"),
              "status" => Schema.string_prop("Optional status filter"),
              "limit" => Schema.integer_prop("Page size"),
              "offset" => Schema.integer_prop("Offset")
            })
          )
      },
      %{
        name: "get_route_analytics",
        description: "Route metrics time-series. #{@window_description}",
        input_schema:
          Schema.object_schema(
            Map.merge(time_props, %{
              "route_id" => route_id,
              "max_points" => Schema.integer_prop("Max chart points")
            }),
            ["route_id"]
          )
      },
      %{
        name: "get_routes_status_analytics",
        description: "Fleet route status time-series. #{@window_description}",
        input_schema: Schema.object_schema(time_props)
      }
    ]
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in Enum.map(definitions(), & &1.name)

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call("get_route_events", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         result <- RouteAnalytics.route_events(route_id, args) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("get_route_pipeline_logs", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         result <- RouteAnalytics.route_pipeline_logs(route_id, args) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("get_route_pipeline_log_distinct", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         {:ok, column} <- Schema.param(args, "column"),
         result <- RouteAnalytics.route_pipeline_log_distinct(route_id, column) do
      {:ok, Helpers.from_result(result)}
    end
  end

  def call("get_routes_status_history", args) do
    case RouteAnalytics.routes_status_history(args) do
      {:ok, payload} -> {:ok, Helpers.from_result({:ok, payload})}
      {:error, {:bad_request, message}} -> {:ok, Helpers.error_response(message)}
      error -> {:ok, Helpers.from_result(error)}
    end
  end

  def call("get_route_analytics", args) do
    with {:ok, route_id} <- Schema.param(args, "route_id"),
         result <- RouteAnalytics.route_timeseries(route_id, args) do
      case result do
        {:ok, payload} -> {:ok, Helpers.from_result({:ok, payload})}
        {:error, {:bad_request, message}} -> {:ok, Helpers.error_response(message)}
        error -> {:ok, Helpers.from_result(error)}
      end
    end
  end

  def call("get_routes_status_analytics", args) do
    case RouteAnalytics.routes_status_timeseries(args) do
      {:ok, payload} -> {:ok, Helpers.from_result({:ok, payload})}
      {:error, {:bad_request, message}} -> {:ok, Helpers.error_response(message)}
      error -> {:ok, Helpers.from_result(error)}
    end
  end

  def call(_name, _args), do: :unknown
end
