import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hydra_srt start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hydra_srt, HydraSrtWeb.Endpoint, server: true
end

if config_env() != :test do
  export_metrics? =
    !!(System.get_env("VICTORIOMETRICS_HOST") && System.get_env("VICTORIOMETRICS_PORT"))

  config :hydra_srt,
    export_metrics?: export_metrics?,
    api_auth_username:
      System.get_env("API_AUTH_USERNAME") || raise("API_AUTH_USERNAME is not set"),
    api_auth_password:
      System.get_env("API_AUTH_PASSWORD") || raise("API_AUTH_PASSWORD is not set")

  # database_path =
  #   System.get_env("DATABASE_PATH") ||
  #     raise """
  #     environment variable DATABASE_PATH is missing.
  #     For example: /etc/hydra_srt/hydra_srt.db
  #     """

  # config :hydra_srt, HydraSrt.Repo,
  #   database: database_path,
  #   pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # secret_key_base =
  #   System.get_env("SECRET_KEY_BASE") ||
  #     raise """
  #     environment variable SECRET_KEY_BASE is missing.
  #     You can generate one by calling: mix phx.gen.secret
  #     """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # config :hydra_srt, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :hydra_srt, HydraSrtWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: nil

  if export_metrics? do
    config :hydra_srt, HydraSrt.Metrics.Connection,
      host: System.get_env("VICTORIOMETRICS_HOST"),
      port: System.get_env("VICTORIOMETRICS_PORT"),
      version: :v2
  end
end
