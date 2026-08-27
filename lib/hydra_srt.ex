defmodule HydraSrt do
  @moduledoc false
  require Logger
  alias HydraSrt.Db
  alias HydraSrt.Stats.EventLogger

  @status_started "started"
  @status_starting "starting"
  @status_stopped "stopped"
  @status_failed "failed"
  @status_completed "completed"
  @route_status_transition_event [:hydra, :route, :status, :transition]

  # Runtime route statuses considered "live" (mirror of LIVE_ROUTE_STATUSES in
  # web_app/src/utils/routes.ts). Used by the RTMP publish gate and any backend
  # logic that needs to treat a route as actively running.
  @live_route_statuses ~w(started processing starting restarting reconnecting)

  @spec live_route_statuses() :: [String.t()]
  def live_route_statuses, do: @live_route_statuses

  @spec live_route_status?(String.t() | nil) :: boolean()
  def live_route_status?(status) when is_binary(status) do
    status in @live_route_statuses
  end

  def live_route_status?(_status), do: false

  # syn releases a route name from a monitor, so the name can still be taken for
  # a moment after the old supervisor is down. Poll instead of racing it.
  @heal_unregister_attempts 50
  @heal_unregister_interval_ms 20
  @probe_timeout_ms :timer.seconds(5)

  @spec stop_route_supervisor(pid()) :: :ok
  def stop_route_supervisor(pid) when is_pid(pid) do
    Supervisor.stop(pid, :normal)
    :ok
  catch
    # An already dead supervisor is the expected race. Anything else means the
    # stop itself failed, so say so rather than reporting a clean stop.
    :exit, :noproc ->
      :ok

    :exit, reason ->
      Logger.error("Route supervisor stop failed pid=#{inspect(pid)} reason=#{inspect(reason)}")
      :ok
  end

  @spec await_route_unregistered(String.t(), non_neg_integer()) ::
          :ok | {:error, :still_registered}
  def await_route_unregistered(id, 0) do
    Logger.error("Route name was not released route_id=#{id}")
    {:error, :still_registered}
  end

  def await_route_unregistered(id, attempts) do
    case :syn.lookup(:routes, id) do
      :undefined ->
        :ok

      _registered ->
        Process.sleep(@heal_unregister_interval_ms)
        await_route_unregistered(id, attempts - 1)
    end
  end

  @spec start_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_route(id) do
    result =
      DynamicSupervisor.start_child(
        {:via, PartitionSupervisor, {HydraSrt.DynamicSupervisor, id}},
        {HydraSrt.RoutesSupervisor, %{id: id}}
      )

    case result do
      {:error, {:already_started, supervisor_pid}} = error ->
        case get_route_handler(id) do
          {:ok, _handler_pid} ->
            error

          # Only a supervisor we could actually inspect, and that genuinely holds
          # no handler, is a zombie. A probe that failed says nothing about the
          # supervisor's health, so never kill a route on the strength of it.
          {:error, :route_handler_probe_failed} ->
            error

          {:error, _reason} ->
            Logger.warning("Healing childless route supervisor route_id=#{id}")
            stop_route_supervisor(supervisor_pid)

            case await_route_unregistered(id, @heal_unregister_attempts) do
              :ok ->
                DynamicSupervisor.start_child(
                  {:via, PartitionSupervisor, {HydraSrt.DynamicSupervisor, id}},
                  {HydraSrt.RoutesSupervisor, %{id: id}}
                )

              {:error, reason} ->
                {:error, reason}
            end
        end

      other ->
        other
    end
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
    try do
      with {:ok, supervisor_pid} <- get_route(id) do
        # Supervisor.which_children/1 calls with :infinity, so a wedged
        # supervisor would hang every caller of this function, the Start
        # endpoint included. Bound the probe instead.
        case GenServer.call(supervisor_pid, :which_children, @probe_timeout_ms) do
          children when is_list(children) ->
            case Enum.find(children, fn
                   {_child_id, pid, :worker, [HydraSrt.RouteHandler]} when is_pid(pid) ->
                     # Process.alive? raises on a remote pid, and the routes syn
                     # scope is cluster wide, so only probe local handlers.
                     node(pid) != node() or Process.alive?(pid)

                   _ ->
                     false
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
    catch
      # A supervisor that died between the lookup and the probe really is gone.
      :exit, {:noproc, _call} ->
        {:error, :route_handler_not_found}

      :exit, :noproc ->
        {:error, :route_handler_not_found}

      # Anything else - a timeout, an unreachable node - says nothing about
      # whether a handler exists. Report the probe failure so callers cannot
      # treat a live route as a zombie and restart it.
      :exit, reason ->
        Logger.warning("Route handler probe failed route_id=#{id} reason=#{inspect(reason)}")
        {:error, :route_handler_probe_failed}
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
    with {:ok, %{route: route, previous_status: previous_status}} <-
           Db.update_route_status_with_previous(id, route_runtime_status_attrs(status)) do
      :ok = emit_route_status_transition(id, previous_status, route_runtime_status(route))
      :ok = broadcast_route_items_status_for_id(id)
      {:ok, route}
    end
  end

  @spec set_route_schema_status(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_route_schema_status(id, schema_status) do
    Db.update_route_schema_status(id, schema_status)
  end

  @spec set_route_runtime_status(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_route_runtime_status(id, status) do
    with {:ok, %{route: route, previous_status: previous_status}} <-
           Db.update_route_runtime_status_with_previous(id, status) do
      :ok = emit_route_status_transition(id, previous_status, route_runtime_status(route))
      :ok = broadcast_route_items_status_for_id(id)
      {:ok, route}
    end
  end

  @spec mark_route_started(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_started(id), do: mark_route_with_terminal_stats(id, @status_starting)

  @spec mark_route_stopped(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_stopped(id), do: mark_route_with_terminal_stats(id, @status_stopped)

  @spec mark_route_completed(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_completed(id), do: mark_route_with_terminal_stats(id, @status_completed)

  @spec mark_route_with_terminal_stats(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_route_with_terminal_stats(id, status) do
    with {:ok, %{route: route, previous_status: previous_status}} <-
           Db.transition_route_runtime_status_with_previous(
             id,
             route_runtime_status_attrs(status) |> Map.put("schema_status", status),
             status,
             status
           ) do
      :ok = emit_route_status_transition(id, previous_status, route_runtime_status(route))
      :ok = broadcast_route_items_status_for_id(id)
      :ok = publish_terminal_zero_stats(route)
      {:ok, route}
    end
  end

  @spec mark_route_failed(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_failed(id) do
    with {:ok, %{route: route, previous_status: previous_status}} <-
           Db.transition_route_runtime_status_with_previous(
             id,
             route_runtime_status_attrs(@status_failed)
             |> Map.put("schema_status", @status_failed),
             @status_failed,
             @status_failed
           ) do
      :ok = emit_route_status_transition(id, previous_status, route_runtime_status(route))
      :ok = broadcast_route_items_status_for_id(id)
      {:ok, route}
    end
  end

  @spec mark_route_terminated(String.t()) :: {:ok, map()} | {:error, term()}
  def mark_route_terminated(id) do
    set_route_status(id, @status_stopped)
  end

  @doc false
  def broadcast_route_items_status(route) when is_map(route) do
    route_id = route["id"]
    route_status = route["schema_status"] || route["status"]
    :ok = broadcast_item_status(route_id, route_status)

    route
    |> Map.get("sources", [])
    |> Enum.each(fn source ->
      :ok = broadcast_item_status(source["id"], source["status"])
    end)

    route
    |> Map.get("destinations", [])
    |> Enum.each(fn destination ->
      :ok = broadcast_item_status(destination["id"], destination["status"])
    end)

    :ok
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
      status when status in [@status_started, @status_starting] ->
        %{
          "status" => status,
          "started_at" => now,
          "stopped_at" => nil
        }

      status when status in [@status_stopped, @status_failed, @status_completed] ->
        %{
          "status" => status,
          "stopped_at" => now
        }

      _ ->
        %{"status" => status}
    end
  end

  defp route_runtime_status(route) when is_map(route) do
    route["schema_status"] || route["status"]
  end

  defp emit_route_status_transition(route_id, previous_status, next_status) do
    if previous_status != next_status do
      :telemetry.execute(
        @route_status_transition_event,
        %{count: 1},
        %{route_id: route_id, from: previous_status, to: next_status}
      )

      EventLogger.log_route_status_change(route_id, previous_status, next_status)
    end

    :ok
  end

  defp broadcast_route_items_status_for_id(route_id) when is_binary(route_id) do
    case Db.get_route(route_id, true) do
      {:ok, route} -> broadcast_route_items_status(route)
      {:error, _reason} -> :ok
    end
  end

  @doc false
  def publish_terminal_zero_stats(route) when is_map(route) do
    route_id = route["id"]

    if is_binary(route_id) do
      destinations =
        route
        |> Map.get("destinations", [])
        |> Enum.filter(&(&1["enabled"] == true))
        |> Enum.flat_map(fn
          %{"id" => id} when is_binary(id) ->
            [%{"id" => id, "bytes_out_per_sec" => 0}]

          _ ->
            []
        end)

      HydraSrt.RouteHandler.publish_stats(
        route_id,
        %{
          "source" => %{"bytes_in_per_sec" => 0},
          "destinations" => destinations
        },
        %{
          active_source_id: route["active_source_id"]
        }
      )
    end

    :ok
  end

  def publish_terminal_zero_stats(_route), do: :ok
end
