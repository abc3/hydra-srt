defmodule HydraSrt.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {HydraSrt.SignalHandler, []}
      )

    :syn.add_node_to_scopes([:routes])
    runtime_schedulers = System.schedulers_online()

    children = [
      HydraSrtWeb.Telemetry,
      HydraSrt.PromEx,
      HydraSrt.ErlSysMon,
      {PartitionSupervisor,
       child_spec: DynamicSupervisor, strategy: :one_for_one, name: HydraSrt.DynamicSupervisor},
      {Registry,
       keys: :unique, name: HydraSrt.Registry.MsgHandlers, partitions: runtime_schedulers},
      HydraSrt.Repo,
      HydraSrt.AuthCleanup,
      {Task.Supervisor, name: HydraSrt.TaskSupervisor},
      {Adbc.Database,
       driver: :duckdb,
       path: Application.fetch_env!(:hydra_srt, :analytics_database_path),
       process_options: [name: HydraSrt.AnalyticsDb]},
      {Adbc.Connection,
       database: HydraSrt.AnalyticsDb, process_options: [name: HydraSrt.AnalyticsConn]},
      {HydraSrt.Stats.Collector, %{}},
      {HydraSrt.Stats.EventLogger, %{}},
      HydraSrt.Stats.Cleaner,
      # {Ecto.Migrator,
      #  repos: Application.fetch_env!(:hydra_srt, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: HydraSrt.PubSub, partitions: runtime_schedulers},
      HydraSrtWeb.Endpoint
    ]

    # Cachex is used by API auth; keep it always available.
    children = [{Cachex, name: HydraSrt.Cache} | children]

    opts = [strategy: :one_for_one, name: HydraSrt.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)
    :ok = HydraSrt.Auth.startup_cleanup()
    :ok = recover_routes_after_startup()
    {:ok, pid}
  end

  @impl true
  def config_change(changed, _new, removed) do
    HydraSrtWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping application")
  end

  @doc false
  def recover_routes_after_startup do
    log_stale_runtime_statuses()
    kill_stale_pipeline_processes()

    reset_counts = HydraSrt.Db.reset_runtime_statuses_to_stopped()

    Logger.info(
      "Startup route recovery reset #{reset_counts.routes} routes and #{reset_counts.destinations} destinations to stopped"
    )

    HydraSrt.Db.list_enabled_routes()
    |> Enum.each(&start_enabled_route/1)

    :ok
  end

  defp log_stale_runtime_statuses do
    HydraSrt.Db.list_routes_with_stale_runtime_status()
    |> Enum.each(fn route ->
      Logger.error(
        "Startup route recovery found stale route status route_id=#{route.id} status=#{inspect(route.status)}"
      )
    end)

    HydraSrt.Db.list_destinations_with_stale_runtime_status()
    |> Enum.each(fn destination ->
      Logger.error(
        "Startup route recovery found stale destination status destination_id=#{destination.id} route_id=#{destination.route_id} status=#{inspect(destination.status)}"
      )
    end)
  end

  defp kill_stale_pipeline_processes do
    {:ok, routes} = HydraSrt.Db.get_all_routes(false)

    Enum.each(routes, fn %{"id" => route_id} ->
      case HydraSrt.ProcessMonitor.kill_pipeline_processes_for_route(route_id) do
        {:ok, _results} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Startup route recovery failed to kill stale pipeline processes route_id=#{route_id} reason=#{inspect(reason)}"
          )
      end
    end)
  end

  defp start_enabled_route(route) do
    Logger.info("Startup route recovery starting enabled route route_id=#{route.id}")

    case HydraSrt.start_route(route.id) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Startup route recovery failed to start enabled route route_id=#{route.id} reason=#{inspect(reason)}"
        )
    end
  end
end
