defmodule HydraSrt.Mcp.Tools.Nodes do
  @moduledoc false

  alias HydraSrt.Mcp.Helpers
  alias HydraSrt.Mcp.Tools.Routes, as: Schema
  alias HydraSrt.Nodes

  @window_description """
  Time range: window one of last_30_min, last_hour, last_6_hour, last_24_hour, or custom from+to ISO8601. \
  Do not use window live; send explicit from/to for polling.
  """

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "list_nodes",
        description: "List cluster nodes with CPU/RAM/network stats (local node only today).",
        input_schema: Schema.object_schema(%{})
      },
      %{
        name: "get_self_node",
        description: "Get stats for the local node (no node_id parameter).",
        input_schema: Schema.object_schema(%{})
      },
      %{
        name: "get_node_analytics",
        description:
          "Node metrics time-series. #{@window_description} node_id must match host from list_nodes/get_self_node.",
        input_schema:
          Schema.object_schema(
            %{
              "node_id" => Schema.string_prop("Node host/id from list_nodes"),
              "window" => Schema.string_prop("Preset window"),
              "from" => Schema.string_prop("Custom range start ISO8601"),
              "to" => Schema.string_prop("Custom range end ISO8601"),
              "max_points" => Schema.integer_prop("Max chart points")
            },
            ["node_id"]
          )
      }
    ]
  end

  @spec handles?(String.t()) :: boolean()
  def handles?(name), do: name in Enum.map(definitions(), & &1.name)

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call("list_nodes", _args) do
    {:ok, Helpers.ok(Nodes.list())}
  end

  def call("get_self_node", _args) do
    {:ok, Helpers.ok(Nodes.self_stats())}
  end

  def call("get_node_analytics", args) do
    with {:ok, node_id} <- Schema.param(args, "node_id"),
         result <- Nodes.analytics(node_id, args) do
      case result do
        {:ok, payload} -> {:ok, Helpers.ok(payload)}
        {:error, {:bad_request, message}} -> {:ok, Helpers.error_response(message)}
        error -> {:ok, Helpers.from_result(error)}
      end
    end
  end

  def call(_name, _args), do: :unknown
end
