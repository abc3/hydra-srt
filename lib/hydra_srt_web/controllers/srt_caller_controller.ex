defmodule HydraSrtWeb.SrtCallerController do
  use HydraSrtWeb, :controller

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.CallerLabels
  alias HydraSrt.Db
  alias HydraSrt.RouteHandler
  alias HydraSrt.Sources

  action_fallback HydraSrtWeb.FallbackController

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def index(conn, %{"route_id" => route_id}) when is_binary(route_id) do
    with {:ok, _route} <- Db.get_route(route_id, true),
         {:ok, callers} <- live_callers(route_id) do
      json(conn, %{data: callers, meta: %{connected_callers: length(callers)}})
    end
  end

  @spec ban(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def ban(conn, %{"route_id" => route_id, "ip" => ip}) when is_binary(route_id) do
    case CallerLabels.valid_address?(ip) and not String.contains?(ip, "/") do
      true -> ban_ip(conn, route_id, ip)
      false -> invalid_ip(conn)
    end
  end

  def ban(conn, %{"route_id" => _route_id}), do: invalid_ip(conn)

  @spec live_callers(String.t()) :: {:ok, [map()]} | {:error, term()}
  def live_callers(route_id) when is_binary(route_id) do
    case HydraSrt.get_route_handler(route_id) do
      {:ok, pid} -> RouteHandler.get_srt_callers(pid)
      {:error, _reason} -> {:ok, []}
    end
  end

  @spec ban_ip(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t() | {:error, term()}
  def ban_ip(conn, route_id, ip) when is_binary(route_id) and is_binary(ip) do
    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source} <- active_srt_listener_source(route),
         denied_list <- Endpoint.decode_ip_access_list(source["denied_list"]),
         updated_denied_list <- append_denied_ip(denied_list, ip),
         {:ok, updated_source} <- update_source_access(route_id, source, updated_denied_list) do
      json(conn, %{
        data: %{
          endpoint_id: updated_source["id"],
          limit_access: updated_source["limit_access"],
          denied_list: updated_source["denied_list"]
        }
      })
    end
  end

  @spec active_srt_listener_source(map()) :: {:ok, map()} | {:error, :not_found}
  def active_srt_listener_source(route) when is_map(route) do
    active_source_id = route["active_source_id"]

    case Enum.find(route["sources"] || [], fn source ->
           source["id"] == active_source_id and source["schema"] == "SRT" and
             source["mode"] == "listener"
         end) do
      source when is_map(source) -> {:ok, source}
      _ -> {:error, :not_found}
    end
  end

  @spec append_denied_ip([String.t()], String.t()) :: [String.t()]
  def append_denied_ip(denied_list, ip) when is_list(denied_list) and is_binary(ip) do
    if Enum.any?(denied_list, &CallerLabels.ip_in_network?(ip, &1)) do
      denied_list
    else
      suffix = if String.contains?(ip, ":"), do: "/128", else: "/32"
      denied_list ++ [ip <> suffix]
    end
  end

  @spec update_source_access(String.t(), map(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def update_source_access(route_id, source, denied_list)
      when is_binary(route_id) and is_map(source) and is_list(denied_list) do
    if source["limit_access"] == true and denied_list == source["denied_list"] do
      {:ok, source}
    else
      Sources.update(route_id, source["id"], %{
        "limit_access" => true,
        "denied_list" => denied_list
      })
    end
  end

  @spec invalid_ip(Plug.Conn.t()) :: Plug.Conn.t()
  def invalid_ip(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "ip must be a valid IPv4 or IPv6 address"})
  end
end
