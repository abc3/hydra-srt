defmodule HydraSrt.ThumbnailManager do
  @moduledoc false
  use GenServer
  require Logger

  @reconcile_interval_ms 5_000
  @running_statuses MapSet.new([
                      "starting",
                      "started",
                      "processing",
                      "reconnecting",
                      "restarting"
                    ])

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :reconcile_interval_ms, @reconcile_interval_ms)
    state = %{interval_ms: interval_ms}
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:noreply, state}
  end

  @spec reconcile() :: :ok
  def reconcile do
    with {:ok, routes} <- HydraSrt.Db.get_all_routes(false) do
      desired = desired_workers(routes)
      current = current_workers()

      current
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(desired, &1))
      |> Enum.each(&stop_worker/1)

      desired
      |> Enum.reject(&Map.has_key?(current, &1))
      |> Enum.each(&start_worker/1)
    else
      {:error, reason} ->
        Logger.warning(
          "ThumbnailManager: failed to reconcile thumbnail workers: #{inspect(reason)}"
        )
    end

    :ok
  end

  @spec stop_route_workers(String.t()) :: :ok
  def stop_route_workers(route_id) when is_binary(route_id) do
    current_workers()
    |> Map.keys()
    |> Enum.filter(fn {worker_route_id, _source_id} -> worker_route_id == route_id end)
    |> Enum.each(&stop_worker/1)

    :ok
  end

  @spec desired_workers([map()]) :: MapSet.t({String.t(), String.t()})
  def desired_workers(routes) when is_list(routes) do
    routes
    |> Enum.flat_map(&desired_workers_for_route/1)
    |> MapSet.new()
  end

  @spec desired_workers_for_route(map()) :: [{String.t(), String.t()}]
  def desired_workers_for_route(route) when is_map(route) do
    route_id = route["id"]
    active_source_id = route["active_source_id"]
    running? = route_running?(route)

    route
    |> Map.get("sources", [])
    |> Enum.filter(&always_thumbnail_source?/1)
    |> Enum.reject(fn source -> running? and source["id"] == active_source_id end)
    |> Enum.map(fn source -> {route_id, source["id"]} end)
    |> Enum.filter(fn {candidate_route_id, candidate_source_id} ->
      is_binary(candidate_route_id) and is_binary(candidate_source_id)
    end)
  end

  @spec route_running?(map()) :: boolean()
  def route_running?(route) when is_map(route) do
    status =
      route
      |> Map.get("schema_status", Map.get(route, "status"))
      |> to_string()
      |> String.downcase()

    MapSet.member?(@running_statuses, status)
  end

  @spec always_thumbnail_source?(map()) :: boolean()
  def always_thumbnail_source?(source) when is_map(source) do
    source["enabled"] == true and source["thumbnail_enabled"] == true and
      source["thumbnail_capture_policy"] == "always"
  end

  def always_thumbnail_source?(_source), do: false

  @spec current_workers() :: map()
  def current_workers do
    HydraSrt.ThumbnailSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce(%{}, fn
      {{:thumbnail_worker, route_id, source_id}, pid, :worker, [HydraSrt.ThumbnailWorker]}, acc
      when is_pid(pid) ->
        Map.put(acc, {route_id, source_id}, pid)

      _child, acc ->
        acc
    end)
  catch
    :exit, _reason -> %{}
  end

  @spec start_worker({String.t(), String.t()}) :: :ok
  def start_worker({route_id, source_id}) do
    case DynamicSupervisor.start_child(
           HydraSrt.ThumbnailSupervisor,
           {HydraSrt.ThumbnailWorker, %{route_id: route_id, source_id: source_id}}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ThumbnailManager: failed to start thumbnail worker route_id=#{route_id} source_id=#{source_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @spec stop_worker({String.t(), String.t()}) :: :ok
  def stop_worker({route_id, source_id} = key) do
    case Map.get(current_workers(), key) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(HydraSrt.ThumbnailSupervisor, pid)

      _ ->
        :ok
    end

    Logger.debug("ThumbnailManager: stopped worker route_id=#{route_id} source_id=#{source_id}")
    :ok
  end
end
