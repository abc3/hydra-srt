import Config

test_args = System.argv()

e2e_mode_enabled? =
  System.get_env("E2E") == "true" or
    Enum.chunk_every(test_args, 2, 1, :discard)
    |> Enum.any?(fn
      ["--only", tag] -> String.starts_with?(tag, "e2e")
      ["--include", tag] -> String.starts_with?(tag, "e2e")
      _ -> false
    end)

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
test_database_path =
  if e2e_mode_enabled? do
    System.get_env("E2E_DATABASE_PATH") ||
      Path.join(System.tmp_dir!(), "hydra_srt_e2e_#{System.unique_integer([:positive])}.db")
  else
    System.get_env("UNIT_DATABASE_PATH") ||
      Path.join(
        System.tmp_dir!(),
        "hydra_srt_unit_test_#{System.get_env("MIX_TEST_PARTITION") || "0"}_#{System.unique_integer([:positive])}.db"
      )
  end

config :hydra_srt, HydraSrt.Repo,
  # Use an isolated per-run SQLite DB file to prevent leaked state from previous runs
  # (including E2E runs) from breaking unit tests.
  #
  # Note: `mix test` alias runs `ecto.create` and `ecto.migrate`, so a fresh DB path
  # per run is safe and keeps the suite deterministic.
  database: test_database_path,
  pool_size: if(e2e_mode_enabled?, do: 2, else: 5),
  pool: if(e2e_mode_enabled?, do: DBConnection.ConnectionPool, else: Ecto.Adapters.SQL.Sandbox),
  queue_target: if(e2e_mode_enabled?, do: 5_000, else: 50),
  queue_interval: if(e2e_mode_enabled?, do: 5_000, else: 1_000),
  journal_mode: :wal,
  # E2E shares one DB across HTTP + Repo; longer busy wait reduces `database is locked`
  # under load (see test_helper E2E max_cases: 1 as well).
  busy_timeout: if(e2e_mode_enabled?, do: 15_000, else: 2_000)

config :hydra_srt,
  analytics_database_path:
    Path.join(
      System.tmp_dir!(),
      "hydra_srt_analytics_test_#{System.unique_integer([:positive])}.duckdb"
    )

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
  default_bind_ip: "127.0.0.1"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
