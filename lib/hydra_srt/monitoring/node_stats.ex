defmodule HydraSrt.Monitoring.NodeStats do
  @moduledoc false

  alias HydraSrt.PromEx.Plugins.OsMon

  @spec all_nodes() :: [map()]
  def all_nodes do
    [self_node_stats()]
  end

  @spec self_node_stats() :: map()
  def self_node_stats do
    stats = OsMon.get_stats()

    la_string =
      if is_map(stats) and is_map(stats.cpu_la) do
        "#{format_float(stats.cpu_la.avg1)} / #{format_float(stats.cpu_la.avg5)} / #{format_float(stats.cpu_la.avg15)}"
      else
        "N/A / N/A / N/A"
      end

    %{
      host: node(),
      cpu: if(is_map(stats), do: stats.cpu, else: nil),
      ram: if(is_map(stats), do: stats.ram, else: nil),
      swap: if(is_map(stats), do: stats.swap, else: nil),
      la: la_string,
      status: "self"
    }
  end

  @spec fallback_node_stats(atom()) :: map()
  def fallback_node_stats(node_name) do
    %{
      host: node_name,
      cpu: nil,
      ram: nil,
      swap: nil,
      la: "N/A / N/A / N/A",
      status: "down"
    }
  end

  @spec format_float(term()) :: String.t()
  def format_float(nil), do: "N/A"
  def format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  def format_float(_), do: "N/A"
end
