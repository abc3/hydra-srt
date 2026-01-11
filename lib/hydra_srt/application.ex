defmodule HydraSrt.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    env = Application.get_env(:hydra_srt, :env, :prod)

    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {HydraSrt.SignalHandler, []}
      )

    :syn.add_node_to_scopes([:routes])
    runtime_schedulers = System.schedulers_online()
    Logger.info("Runtime schedulers: #{runtime_schedulers}")

    # The native pipeline connects to a UNIX domain socket for stats/telemetry.
    # Unit tests don't need this listener, but E2E tests do (they run under MIX_ENV=test).
    if env != :test or System.get_env("E2E") == "true" or System.get_env("E2E_UI") == "true" do
      socket_path = "/tmp/hydra_unix_sock"

      # Best-effort cleanup in case a previous run crashed and left a stale socket file.
      _ = File.rm(socket_path)

      {:ok, ranch_listener} =
        :ranch.start_listener(
          :hydra_unix_sock,
          :ranch_tcp,
          %{
            max_connections: String.to_integer(System.get_env("MAX_CONNECTIONS") || "75000"),
            num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
            socket_opts: [
              ip: {:local, socket_path},
              port: 0,
              keepalive: true
            ]
          },
          HydraSrt.UnixSockHandler,
          %{}
        )

      Logger.info("Ranch listener: #{inspect(ranch_listener)}")
    end

    children = [
      HydraSrt.ErlSysMon,
      {PartitionSupervisor,
       child_spec: DynamicSupervisor, strategy: :one_for_one, name: HydraSrt.DynamicSupervisor},
      {Registry,
       keys: :unique, name: HydraSrt.Registry.MsgHandlers, partitions: runtime_schedulers},
      HydraSrtWeb.Telemetry,
      HydraSrt.Repo,
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
