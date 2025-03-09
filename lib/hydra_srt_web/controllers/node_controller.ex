defmodule HydraSrtWeb.NodeController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Monitoring.OsMon

  def index(conn, _params) do
    nodes = [node() | Node.list()]

    node_stats =
      Enum.map(nodes, fn node_name ->
        try do
          stats = :rpc.call(node_name, OsMon, :get_all_stats, [])

          status =
            if is_map(stats) and (is_number(stats.cpu) or is_number(stats.ram)),
              do: "up",
              else: "down"

          status = if node_name == node(), do: "self", else: status

          la_string =
            if is_map(stats) and is_map(stats.cpu_la) do
              "#{format_float(stats.cpu_la.avg1)} / #{format_float(stats.cpu_la.avg5)} / #{format_float(stats.cpu_la.avg15)}"
            else
              "N/A / N/A / N/A"
            end

          %{
            host: node_name,
            cpu: if(is_map(stats), do: stats.cpu, else: nil),
            ram: if(is_map(stats), do: stats.ram, else: nil),
            swap: if(is_map(stats), do: stats.swap, else: nil),
            la: la_string,
            status: status
          }
        rescue
          _ ->
            %{
              host: node_name,
              cpu: nil,
              ram: nil,
              swap: nil,
              la: "N/A / N/A / N/A",
              status: "down"
            }
        catch
          _, _ ->
            %{
              host: node_name,
              cpu: nil,
              ram: nil,
              swap: nil,
              la: "N/A / N/A / N/A",
              status: "down"
            }
        end
      end)

    json(conn, node_stats)
  end

  def show(conn, %{"id" => node_name}) do
    node_atom = String.to_atom(node_name)

    try do
      stats = :rpc.call(node_atom, OsMon, :get_all_stats, [])

      status =
        if is_map(stats) and (is_number(stats.cpu) or is_number(stats.ram)),
          do: "up",
          else: "down"

      status = if node_atom == node(), do: "self", else: status

      la_string =
        if is_map(stats) and is_map(stats.cpu_la) do
          "#{format_float(stats.cpu_la.avg1)} / #{format_float(stats.cpu_la.avg5)} / #{format_float(stats.cpu_la.avg15)}"
        else
          "N/A / N/A / N/A"
        end

      node_data = %{
        host: node_atom,
        cpu: if(is_map(stats), do: stats.cpu, else: nil),
        ram: if(is_map(stats), do: stats.ram, else: nil),
        swap: if(is_map(stats), do: stats.swap, else: nil),
        la: la_string,
        status: status
      }

      json(conn, node_data)
    rescue
      e ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Node not available: #{inspect(e)}"})
    catch
      _, reason ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Node not available: #{inspect(reason)}"})
    end
  end

  defp format_float(nil), do: "N/A"
  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_float(_), do: "N/A"
end
