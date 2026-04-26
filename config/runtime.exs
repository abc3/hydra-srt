import Config

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

present? = fn
  nil -> false
  s when is_binary(s) -> String.trim(s) != ""
  _ -> false
end

if System.get_env("PHX_SERVER") do
  config :hydra_srt, HydraSrtWeb.Endpoint, server: true
end

secret_key_base =
  cond do
    config_env() == :dev ->
      System.get_env("SECRET_KEY_BASE") ||
        "9re8gLwrcmLnNcUbxe8xgKSCNfm8gIpgoBBiCXhV0dVfJMB8DVFB3QQJwOye0iIo"

    config_env() == :test ->
      System.get_env("SECRET_KEY_BASE") ||
        "o4JBd+wOK5JJIHHOZ/WMk00xrG9dN0//FF1MIBkDPzM+nRTN+5+L9hvMVX+805L0"

    true ->
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
  end

config :hydra_srt, HydraSrtWeb.Endpoint, secret_key_base: secret_key_base

unless config_env() == :test do
  config :hydra_srt,
    default_bind_ip: System.get_env("HYDRA_DEFAULT_BIND_IP") || "127.0.0.1"
end

case config_env() do
  :prod ->
    config :hydra_srt,
      api_auth_username:
        System.get_env("API_AUTH_USERNAME") || raise("API_AUTH_USERNAME is not set"),
      api_auth_password:
        System.get_env("API_AUTH_PASSWORD") || raise("API_AUTH_PASSWORD is not set")

    database_path =
      System.get_env("DATABASE_PATH") ||
        raise """
        environment variable DATABASE_PATH is missing.
        For example: /etc/hydra_srt/hydra_srt.db
        """

    config :hydra_srt, HydraSrt.Repo,
      database: database_path,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
      journal_mode: :wal

    analytics_database_path =
      System.get_env("ANALYTICS_DATABASE_PATH") ||
        raise """
        environment variable ANALYTICS_DATABASE_PATH is missing.
        For example: /etc/hydra_srt/hydra_srt_analytics.duckdb
        """

    config :hydra_srt, analytics_database_path: analytics_database_path

    host = System.get_env("PHX_HOST") || "example.com"
    port = String.to_integer(System.get_env("PORT") || "4000")

    config :hydra_srt, HydraSrtWeb.Endpoint,
      url: [host: host, port: port, scheme: "http"],
      http: [
        ip: {0, 0, 0, 0},
        port: port
      ]

  :dev ->
    port = String.to_integer(System.get_env("PORT") || "4000")
    host = System.get_env("PHX_HOST") || "localhost"

    config :hydra_srt, HydraSrtWeb.Endpoint,
      url: [host: host, port: port, scheme: "http"],
      http: [ip: {127, 0, 0, 1}, port: port]

    if path = System.get_env("DATABASE_PATH") do
      config :hydra_srt, HydraSrt.Repo,
        database: path,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
    end

    analytics_database_path =
      System.get_env("ANALYTICS_DATABASE_PATH") ||
        raise """
        environment variable ANALYTICS_DATABASE_PATH is missing.
        For example: /tmp/hydra_srt_analytics.duckdb
        """

    config :hydra_srt, analytics_database_path: analytics_database_path

    if u = System.get_env("API_AUTH_USERNAME") do
      config :hydra_srt, api_auth_username: u
    end

    if p = System.get_env("API_AUTH_PASSWORD") do
      config :hydra_srt, api_auth_password: p
    end

  _ ->
    :ok
end

if config_env() == :test and System.get_env("E2E_UI") == "true" do
  port = String.to_integer(System.get_env("E2E_PORT") || "4000")

  config :hydra_srt, HydraSrtWeb.Endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: port]
end
