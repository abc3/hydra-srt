defmodule HydraSrt.RouteControl do
  @moduledoc false

  alias HydraSrt.Db

  @spec switch_route_source(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def switch_route_source(route_id, source_id)
      when is_binary(route_id) and is_binary(source_id) do
    with {:ok, source} <- Db.get_source(route_id, source_id),
         true <- source["enabled"] == true or {:error, :source_disabled},
         {:ok, route} <- switch_route_source_when_ready(route_id, source_id) do
      {:ok, route}
    end
  end

  @spec route_stopped?(map()) :: boolean()
  def route_stopped?(route) when is_map(route) do
    status = route["status"]
    status in [nil, "", "stopped", "failed"]
  end

  @spec drop_runtime_status_fields(map()) :: map()
  def drop_runtime_status_fields(route_params) when is_map(route_params) do
    route_params
    |> Map.drop(["status", "schema_status"])
    |> Map.drop([:status, :schema_status])
  end

  @spec switch_route_source_when_ready(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def switch_route_source_when_ready(route_id, source_id)
      when is_binary(route_id) and is_binary(source_id) do
    case HydraSrt.get_route_handler(route_id) do
      {:ok, pid} ->
        case HydraSrt.RouteHandler.switch_source_sync(pid, source_id, "manual") do
          :ok -> Db.get_route(route_id, true)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        with {:ok, route} <- Db.get_route(route_id, true),
             true <- route_stopped?(route) or {:error, :route_handler_unavailable} do
          Db.set_route_active_source(route_id, source_id, "manual")
        end
    end
  end
end
