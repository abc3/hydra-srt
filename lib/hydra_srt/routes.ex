defmodule HydraSrt.Routes do
  @moduledoc false

  alias HydraSrt.Db
  alias HydraSrt.Pagination
  alias HydraSrt.RouteControl
  alias HydraSrt.SourceProbe

  @spec list_page(map()) ::
          {:ok,
           %{routes: [map()], page: pos_integer(), limit: pos_integer(), total: non_neg_integer()}}
          | {:error, term()}
  def list_page(params) when is_map(params) do
    page = Pagination.parse_page(params)
    limit = Pagination.parse_limit(params)
    sort_by = Pagination.parse_sort_by(params)

    Db.get_routes_page(true, sort_by, page, min(limit, Pagination.max_limit()))
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(route_id) when is_binary(route_id), do: Db.get_route(route_id, true)

  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(route_params) when is_map(route_params), do: Db.create_route(route_params)

  @spec update(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(route_id, route_params) when is_binary(route_id) and is_map(route_params) do
    Db.update_route(route_id, RouteControl.drop_runtime_status_fields(route_params))
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(route_id) when is_binary(route_id) do
    case Db.delete_route(route_id) do
      [:ok, :ok] -> :ok
      [{:error, reason}] -> {:error, reason}
    end
  end

  @spec start(String.t()) :: {:ok, map()} | {:error, term()}
  def start(route_id) when is_binary(route_id) do
    case HydraSrt.start_route(route_id) do
      {:ok, _pid} -> {:ok, %{status: "starting", route_id: route_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop(String.t()) :: {:ok, map()} | {:error, term()}
  def stop(route_id) when is_binary(route_id) do
    case HydraSrt.stop_route(route_id) do
      :ok -> {:ok, %{status: "stopped", route_id: route_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec restart(String.t()) :: {:ok, map()} | {:error, term()}
  def restart(route_id) when is_binary(route_id) do
    case HydraSrt.restart_route(route_id) do
      {:ok, _pid} -> {:ok, %{status: "restarted", route_id: route_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec switch_source(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def switch_source(route_id, source_id)
      when is_binary(route_id) and is_binary(source_id) do
    RouteControl.switch_route_source(route_id, source_id)
  end

  @spec test_source_config(map()) :: {:ok, map()} | {:error, String.t()}
  def test_source_config(route_params) when is_map(route_params) do
    case SourceProbe.probe(route_params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, SourceProbe.client_error(reason)}
    end
  end
end
