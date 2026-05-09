import Config

alias HydraSrt.Env

# config/runtime.exs runs for every environment (including releases), after
# config/config.exs and config/<env>.exs. Use it for values that come from the
# host (env vars, files), not for compile-time-only options.
#
# Environment variables (non-exhaustive):
# - PHX_SERVER: set to enable the Phoenix endpoint server (releases)
# - SECRET_KEY_BASE: required in prod; optional in dev/test (defaults exist)
# - API_AUTH_USERNAME / API_AUTH_PASSWORD: required in prod; optional in dev
# - DATABASE_PATH: required in prod; optional in dev (overrides dev DB path)
# - ANALYTICS_DATABASE_PATH: required in prod and dev
# - POOL_SIZE: Ecto pool size (prod default 5)
# - PORT / PHX_HOST: HTTP listen port and URL host

if System.get_env("PHX_SERVER") do
  config :hydra_srt, HydraSrtWeb.Endpoint, server: true
end

secret_key_base =
  cond do
    config_env() == :dev ->
      Env.get_binary("SECRET_KEY_BASE", nil) ||
        "9re8gLwrcmLnNcUbxe8xgKSCNfm8gIpgoBBiCXhV0dVfJMB8DVFB3QQJwOye0iIo"

    config_env() == :test ->
      Env.get_binary("SECRET_KEY_BASE", nil) ||
        "o4JBd+wOK5JJIHHOZ/WMk00xrG9dN0//FF1MIBkDPzM+nRTN+5+L9hvMVX+805L0"

    true ->
      Env.get_binary("SECRET_KEY_BASE", nil) ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
  end

config :hydra_srt, HydraSrtWeb.Endpoint, secret_key_base: secret_key_base

unless config_env() == :test do
  system_metrics_history_enabled = Env.get_boolean("SYSTEM_METRICS_HISTORY_ENABLED", true)

  system_metrics_history_interval_ms = Env.get_integer("SYSTEM_METRICS_HISTORY_INTERVAL_MS", 5000)

  config :hydra_srt,
    default_bind_ip: Env.get_binary("HYDRA_DEFAULT_BIND_IP", "127.0.0.1"),
    prom_poll_rate: Env.get_integer("PROM_POLL_RATE", 5000),
    metrics_secret: Env.get_binary("METRICS_SECRET", nil),
    system_metrics_history: [
      enabled: system_metrics_history_enabled,
      flush_interval_ms: system_metrics_history_interval_ms,
      metrics: [:cpu, :mem, :swap, :la]
    ]
end

case config_env() do
  :prod ->
    config :hydra_srt,
      api_auth_username:
        Env.get_binary("API_AUTH_USERNAME", nil) || raise("API_AUTH_USERNAME is not set"),
      api_auth_password:
        Env.get_binary("API_AUTH_PASSWORD", nil) || raise("API_AUTH_PASSWORD is not set")

    database_path =
      Env.get_binary("DATABASE_PATH", nil) ||
        raise """
        environment variable DATABASE_PATH is missing.
        For example: /etc/hydra_srt/hydra_srt.db
        """

    config :hydra_srt, HydraSrt.Repo,
      database: database_path,
      pool_size: Env.get_integer("POOL_SIZE", 5),
      journal_mode: :wal

    analytics_database_path =
      Env.get_binary("ANALYTICS_DATABASE_PATH", nil) ||
        raise """
        environment variable ANALYTICS_DATABASE_PATH is missing.
        For example: /etc/hydra_srt/hydra_srt_analytics.duckdb
        """

    config :hydra_srt, analytics_database_path: analytics_database_path

    host = Env.get_binary("PHX_HOST", "example.com")
    port = Env.get_integer("PORT", 4000)

    config :hydra_srt, HydraSrtWeb.Endpoint,
      url: [host: host, port: port, scheme: "http"],
      http: [
        ip: {0, 0, 0, 0},
        port: port
      ]

  :dev ->
    port = Env.get_integer("PORT", 4000)
    host = Env.get_binary("PHX_HOST", "localhost")

    config :hydra_srt, HydraSrtWeb.Endpoint,
      url: [host: host, port: port, scheme: "http"],
      http: [ip: {127, 0, 0, 1}, port: port]

    if path = Env.get_binary("DATABASE_PATH", nil) do
      config :hydra_srt, HydraSrt.Repo,
        database: path,
        pool_size: Env.get_integer("POOL_SIZE", 5)
    end

    analytics_database_path =
      Env.get_binary("ANALYTICS_DATABASE_PATH", nil) ||
        Path.expand("../hydra_srt_analytics.duckdb", __DIR__)

    config :hydra_srt, analytics_database_path: analytics_database_path

    if u = Env.get_binary("API_AUTH_USERNAME", nil) do
      config :hydra_srt, api_auth_username: u
    end

    if p = Env.get_binary("API_AUTH_PASSWORD", nil) do
      config :hydra_srt, api_auth_password: p
    end

  _ ->
    :ok
end

if config_env() == :test and System.get_env("E2E_UI") == "true" do
  port = Env.get_integer("E2E_PORT", 4000)

  config :hydra_srt, HydraSrtWeb.Endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: port]
end
