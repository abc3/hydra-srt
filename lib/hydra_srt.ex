defmodule HydraSrt do
  @moduledoc false
  require Logger
  alias HydraSrt.Db

  @spec start_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_route(id) do
    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {HydraSrt.DynamicSupervisor, id}},
      {HydraSrt.RoutesSupervisor, %{id: id}}
    )
  end

  @spec get_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def get_route(id) do
    case :syn.lookup(:routes, id) do
      {pid, _} when is_pid(pid) -> {:ok, pid}
      :undefined -> {:error, :not_found}
    end
  end

  @spec get_route_handler(String.t()) :: {:ok, pid()} | {:error, term()}
  def get_route_handler(id) do
    with {:ok, supervisor_pid} <- get_route(id) do
      case Supervisor.which_children(supervisor_pid) do
        children when is_list(children) ->
          case Enum.find(children, fn
                 {_child_id, pid, :worker, [HydraSrt.RouteHandler]} when is_pid(pid) -> true
                 _ -> false
               end) do
            {_child_id, pid, :worker, [HydraSrt.RouteHandler]} ->
              {:ok, pid}

            _ ->
              {:error, :route_handler_not_found}
          end

        _ ->
          {:error, :route_handler_not_found}
      end
    end
  end

  @spec stop_route(String.t()) :: :ok | {:error, term()}
  def stop_route(id) do
    case get_route(id) do
      {:ok, pid} ->
        Supervisor.stop(pid, :normal)

      other ->
        HydraSrt.mark_route_stopped(id)
        other
    end
  end

  @spec restart_route(String.t()) :: {:ok, term()} | {:error, term()}
  def restart_route(id) do
    case stop_route(id) do
      {:error, reason} ->
        Logger.warning("Attempt to restart route #{id}, but: #{inspect(reason)}")

      _ ->
        nil
    end

    with {:ok, _pid} <- start_route(id) do
      {:ok, :restarted}
    end
  end

  @spec set_route_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_route_status(id, status) do
    with {:ok, route} <- Db.update_route(id, route_runtime_status_attrs(status)) do
      :ok = broadcast_route_items_status(id)
      {:ok, route}
    end
  end

  @spec set_route_schema_status(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_route_schema_status(id, schema_status) do
    Db.update_route_schema_status(id, schema_status)
  end

  @spec set_route_runtime_status(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_route_runtime_status(id, status) do
    with {:ok, route} <- Db.update_route_runtime_status(id, status) do
      :ok = broadcast_route_items_status(id)
      {:ok, route}
    end
  end

  @spec mark_route_started(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_started(id) do
    :ok = Db.update_destinations_status(id, nil)

    with {:ok, route} <-
           Db.update_route(
             id,
             route_runtime_status_attrs("starting")
             |> Map.put("schema_status", "starting")
           ) do
      :ok = broadcast_route_items_status(id)
      {:ok, route}
    end
  end

  @spec mark_route_stopped(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_stopped(id) do
    :ok = Db.update_destinations_status(id, "stopped")

    with {:ok, route} <-
           Db.update_route(
             id,
             route_runtime_status_attrs("stopped")
             |> Map.put("schema_status", "stopped")
           ) do
      :ok = broadcast_route_items_status(id)
      {:ok, route}
    end
  end

  @spec mark_route_terminated(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_terminated(id) do
    set_route_status(id, "stopped")
  end

  @doc false
  def broadcast_route_items_status(route_id) when is_binary(route_id) do
    case Db.get_route(route_id, true) do
      {:ok, route} ->
        route_status = route["schema_status"] || route["status"]
        :ok = broadcast_item_status(route_id, route_status)

        route
        |> Map.get("destinations", [])
        |> Enum.each(fn destination ->
          :ok = broadcast_item_status(destination["id"], destination["status"])
        end)

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc false
  def broadcast_item_status(item_id, status)
      when is_binary(item_id) and is_binary(status) and status != "" do
    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "item:" <> item_id,
      {:item_status, %{item_id: item_id, status: status}}
    )

    :ok
  end

  @doc false
  def broadcast_item_status(_item_id, _status), do: :ok

  defp route_runtime_status_attrs(status) when is_binary(status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case String.downcase(status) do
      status when status in ["started", "starting"] ->
        %{
          "status" => status,
          "started_at" => now,
          "stopped_at" => nil
        }

      "stopped" ->
        %{
          "status" => status,
          "stopped_at" => now
        }

      _ ->
        %{"status" => status}
    end
  end
end
