defmodule HydraSrtWeb.DashboardController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Db
  alias HydraSrt.Monitoring.OsMon
  alias HydraSrt.ProcessMonitor
  alias HydraSrt.StatsStore

  def summary(conn, _params) do
    routes =
      case Db.get_all_routes(false, "updated_at") do
        {:ok, rs} when is_list(rs) -> rs
        _ -> []
      end

    total_routes = length(routes)

    started_routes =
      Enum.count(routes, fn r ->
        case Map.get(r, "status") do
          s when is_binary(s) -> String.downcase(s) == "started"
          _ -> false
        end
      end)

    enabled_routes = Enum.count(routes, fn r -> Map.get(r, "enabled") == true end)

    pipelines =
      case ProcessMonitor.list_pipeline_processes() do
        ps when is_list(ps) -> ps
        _ -> []
      end

    nodes = [node() | Node.list()]

    {nodes_up, nodes_down} = count_node_health(nodes)

    system_stats = OsMon.get_all_stats()
    throughput = StatsStore.aggregate_throughput()

    json(conn, %{
      routes: %{
        total: total_routes,
        started: started_routes,
        stopped: max(total_routes - started_routes, 0),
        enabled: enabled_routes,
        disabled: max(total_routes - enabled_routes, 0)
      },
      nodes: %{
        total: length(nodes),
        up: nodes_up,
        down: nodes_down
      },
      pipelines: %{
        count: length(pipelines)
      },
      system: %{
        cpu: Map.get(system_stats, :cpu),
        ram: Map.get(system_stats, :ram),
        swap: Map.get(system_stats, :swap),
        la: format_la(Map.get(system_stats, :cpu_la)),
        host: node()
      },
      throughput: throughput
    })
  end

  def count_node_health(nodes) when is_list(nodes) do
    Enum.reduce(nodes, {0, 0}, fn node_name, {up, down} ->
      stats = :rpc.call(node_name, OsMon, :get_all_stats, [], 1_000)

      is_up =
        is_map(stats) and
          (is_number(Map.get(stats, :cpu)) or is_number(Map.get(stats, :ram)))

      if node_name == node() do
        {up + 1, down}
      else
        if is_up, do: {up + 1, down}, else: {up, down + 1}
      end
    end)
  end

  def format_la(%{avg1: a1, avg5: a5, avg15: a15})
      when is_number(a1) and is_number(a5) and is_number(a15) do
    "#{float1(a1)} / #{float1(a5)} / #{float1(a15)}"
  end

  def format_la(_), do: "N/A / N/A / N/A"

  def float1(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  def float1(v) when is_integer(v), do: float1(v * 1.0)
  def float1(_), do: "N/A"
end
