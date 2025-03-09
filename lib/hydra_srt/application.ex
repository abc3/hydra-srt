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

    Logger.info("Starting database: #{inspect(:khepri.start())}")
    :syn.add_node_to_scopes([:routes])
    runtime_schedulers = System.schedulers_online()
    Logger.info("Runtime schedulers: #{runtime_schedulers}")

    {:ok, ranch_listener} =
      :ranch.start_listener(
        :hydra_unix_sock,
        :ranch_tcp,
        %{
          max_connections: String.to_integer(System.get_env("MAX_CONNECTIONS") || "75000"),
          num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
          socket_opts: [
            ip: {:local, "/tmp/hydra_unix_sock"},
            port: 0,
            keepalive: true
          ]
        },
        HydraSrt.UnixSockHandler,
        %{}
      )

    Logger.info("Ranch listener: #{inspect(ranch_listener)}")

    children = [
      HydraSrt.ErlSysMon,
      {PartitionSupervisor,
       child_spec: DynamicSupervisor, strategy: :one_for_one, name: HydraSrt.DynamicSupervisor},
      {Registry,
       keys: :unique, name: HydraSrt.Registry.MsgHandlers, partitions: runtime_schedulers},
      HydraSrtWeb.Telemetry,
      # HydraSrt.Repo,
      # {Ecto.Migrator,
      #  repos: Application.fetch_env!(:hydra_srt, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: HydraSrt.PubSub, partitions: runtime_schedulers},
      HydraSrtWeb.Endpoint,
      HydraSrt.Metrics.Connection
    ]

    # start Cachex only if the node uses names, this is necessary for test setup
    children =
      if node() != :nonode@nohost do
        [{Cachex, name: HydraSrt.Cache} | children]
      else
        children
      end

    opts = [strategy: :one_for_one, name: HydraSrt.Supervisor]
    Supervisor.start_link(children, opts)
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
