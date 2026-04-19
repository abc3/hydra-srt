defmodule HydraSrt.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    :ok = HydraSrt.StatsStore.ensure_table()

    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {HydraSrt.SignalHandler, []}
      )

    :syn.add_node_to_scopes([:routes])
    runtime_schedulers = System.schedulers_online()

    children = [
      HydraSrt.ErlSysMon,
      {PartitionSupervisor,
       child_spec: DynamicSupervisor, strategy: :one_for_one, name: HydraSrt.DynamicSupervisor},
      {Registry,
       keys: :unique, name: HydraSrt.Registry.MsgHandlers, partitions: runtime_schedulers},
      HydraSrtWeb.Telemetry,
      HydraSrt.Repo,
      HydraSrt.AuthCleanup,
      {Task.Supervisor, name: HydraSrt.TaskSupervisor},
      HydraSrt.StatsRetention,
      # {Ecto.Migrator,
      #  repos: Application.fetch_env!(:hydra_srt, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: HydraSrt.PubSub, partitions: runtime_schedulers},
      HydraSrtWeb.Endpoint
    ]

    children =
      if Application.get_env(:hydra_srt, :export_metrics?, true) do
        children ++ [HydraSrt.Metrics.Connection]
      else
        children
      end

    # Cachex is used by API auth and websocket auth; keep it always available.
    children = [{Cachex, name: HydraSrt.Cache} | children]

    opts = [strategy: :one_for_one, name: HydraSrt.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)
    :ok = HydraSrt.Auth.startup_cleanup()
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
end
