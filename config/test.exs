import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :hydra_srt, HydraSrt.Repo,
  # Use an isolated per-run SQLite DB file to prevent leaked state from previous runs
  # (including E2E runs) from breaking unit tests.
  #
  # Note: `mix test` alias runs `ecto.create` and `ecto.migrate`, so a fresh DB path
  # per run is safe and keeps the suite deterministic.
  database:
    System.get_env("UNIT_DATABASE_PATH") ||
      Path.join(
        System.tmp_dir!(),
        "hydra_srt_unit_test_#{System.get_env("MIX_TEST_PARTITION") || "0"}_#{System.unique_integer([:positive])}.db"
      ),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hydra_srt, HydraSrtWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "o4JBd+wOK5JJIHHOZ/WMk00xrG9dN0//FF1MIBkDPzM+nRTN+5+L9hvMVX+805L0",
  server: false

# Defaults for automated UI/E2E tests (Playwright, ExUnit E2E helpers)
config :hydra_srt,
  api_auth_username: "admin",
  api_auth_password: "password123",
  export_metrics?: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
