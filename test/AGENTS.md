# AGENTS.md - HydraSRT Test Guide

## Intent

Stable, reusable patterns for unit, integration, and E2E tests across Elixir, the native Rust pipeline, and the web UI.

## Runtime Baseline

- Elixir `~> 1.18`, OTP `27+`
- See `../AGENTS.md` for project-wide commands and architecture

## Commands

| Layer | Command | Makefile | CI job |
|-------|---------|----------|--------|
| Elixir unit | `mix test` | `make test_backend` | `elixir_test` |
| Elixir E2E | `E2E=true mix test --only e2e` | `make test_e2e` | `elixir_e2e_test` |
| Elixir MCP E2E | `E2E_MCP=true mix test --only e2e_mcp` | `make test_e2e_mcp` | `elixir_e2e_mcp_test` |
| Elixir E2E encrypted | `E2E=true mix test --only encrypted` | `make test_e2e_encrypted` | — |
| Native unit (Rust) | `cd native && cargo test` | `make test_rs_native_unit` | `rs_native_unit_test` |
| Native E2E | `NATIVE_E2E=true mix test test/native_e2e` | `make test_rs_native_e2e` | `rs_native_e2e_test` |
| Web unit (Vitest) | `cd web_app && npm run test:unit` | `make test_web_unit` | `js_unit_test` |
| Web E2E (Playwright) | `cd web_app && npm run test:e2e` | `make test_web_e2e` | `js_e2e_test` |
| All layers (sequential) | — | `make test_all` | — |
| CI-equivalent locally | — | `make test_ci_local` | — |

### Prerequisites by layer

- **Elixir unit** — `mix deps.get`, native binary built for compile (`mix compile` triggers `compile.rs_native`).
- **Elixir E2E** — `ffmpeg`, `srt-tools` (or `srt-live-transmit`) in PATH; native pipeline binary; see `HydraSrt.TestSupport.E2EHelpers`.
- **Elixir MCP E2E** — native pipeline binary and HTTP endpoint only (no ffmpeg/SRT streaming tools); see `HydraSrt.TestSupport.McpE2EClient` and `test/e2e_mcp/`.
- **Elixir E2E encrypted** — ffmpeg/libsrt build with SRT passphrase support; otherwise `:encrypted` tests are auto-excluded.
- **Native unit/E2E** — GStreamer and SRT dev libraries (see CI workflow `apt-get` steps).
- **Web unit** — `cd web_app && npm ci`.
- **Web E2E** — Playwright browsers (`npx playwright install --with-deps`), Elixir backend built, `native` compiled.

### Single file / debug

```bash
mix test test/hydra_srt/route_handler_test.exs
mix test test/hydra_srt/route_handler_test.exs:42
E2E=true mix test test/e2e/srt_pipeline_e2e_test.exs
E2E_MCP=true mix test --only e2e_mcp
E2E_MCP=true mix test --only e2e_mcp --include mcp_probe
mix test test/e2e_mcp/auth_test.exs
mix test test/hydra_srt/db_tokens_test.exs test/hydra_srt_web/controllers/token_controller_test.exs
cd web_app && npm run test:unit:watch
TRACE=true mix test
SLOWEST=true mix test
TEST_TIMEOUT=120000 mix test
E2E_DEBUG_LOGS=true E2E=true mix test --only e2e
```

## Support Modules

### `test/support/`

| Module | Role |
|--------|------|
| `HydraSrt.DataCase` | Ecto tests with SQL Sandbox |
| `HydraSrtWeb.ConnCase` | Phoenix `ConnTest` + sandbox |
| `HydraSrt.TestSupport.E2EHelpers` | E2E prereqs: app/endpoint start, ffmpeg/SRT probes, CI-aware timeouts, pipeline cleanup |
| `HydraSrt.TestSupport.McpE2ECase` | MCP E2E ExUnit template (`test/e2e_mcp/`): Hermes client, fixtures, assertions |
| `HydraSrt.TestSupport.McpE2EProbeCase` | ffprobe probe MCP E2E template (`:mcp_probe` only; opt-in via `--include mcp_probe`) |
| `HydraSrt.TestSupport.McpE2EClient` | Hermes `Client` over Streamable HTTP for `/mcp` |
| `HydraSrt.TestSupport.McpE2EFixtures` | Seeded route/source/destination/tag/interface context for tool calls |
| `HydraSrt.TestSupport.McpE2EAssertions` | Auth rejection and MCP tool response assertions |
| `HydraSrt.ApiFixtures` | API-level test data (`test/support/fixtures/api_fixtures.ex`) |
| `HydraSrt.DbFixtures` | DB fixtures (`test/support/fixtures/db_fixtures.ex`) |

### `test/native_e2e/support/`

| Module | Role |
|--------|------|
| `HydraSrt.E2E.Native.Harness` | Starts and supervises native pipeline processes |
| `HydraSrt.E2E.Native.Helpers` | Shared native E2E utilities |
| `HydraSrt.E2E.Native.ProcessRegistry` | Tracks child processes across tests |
| `HydraSrt.E2E.Native.UdpListener` | UDP sink for native output assertions |

Loaded explicitly from `test/test_helper.exs` when running native E2E.

## ExUnit Tags and `test_helper.exs`

Configured in `test/test_helper.exs`:

| Tag / mode | Default | Enable |
|------------|---------|--------|
| `:e2e` | excluded | `E2E=true` or `mix test --only e2e` |
| `:e2e_mcp` | excluded | `E2E_MCP=true` or `mix test --only e2e_mcp` |
| `:mcp_probe` | excluded | `E2E_MCP=true mix test --only e2e_mcp --include mcp_probe` (ffprobe probes; ~30s extra) |
| `:native_e2e` | excluded | `NATIVE_E2E=true` |
| `:encrypted` | excluded if ffmpeg lacks SRT encryption | `E2E=true mix test --only encrypted` |

**E2E mode behaviour (route and MCP):**

- `ExUnit.configure(max_cases: 1)` — shared SQLite + HTTP endpoint; no parallel E2E.
- Route E2E: `HydraSrt.TestSupport.E2EHelpers.ensure_e2e_prereqs!()` (ffmpeg, native, pipeline cleanup).
- MCP E2E: `HydraSrt.TestSupport.E2EHelpers.ensure_e2e_mcp_prereqs!()` (lighter; no ffmpeg/SRT streaming tools).
- `ExUnit.after_suite/1` kills leftover pipelines after route E2E.

**Unit mode:** SQL Sandbox in manual mode when Repo is running.

### Debug environment variables

| Variable | Effect |
|----------|--------|
| `TRACE=true` | Print each test name as it runs |
| `SLOWEST=true` | Print slowest tests at end |
| `TEST_TIMEOUT=ms` | Per-test timeout override |
| `E2E_DEBUG_LOGS=true` | Full stdout/stderr from external E2E processes |

## Standards

- Follow [../AGENTS.md](../AGENTS.md) Standards (American English, no `defp`, etc.).
- Assert behaviour, not implementation details or log lines.
- Avoid `Process.sleep/1` where a condition can be polled; some tests use local `assert_eventually/eventually` helpers (centralised `Eventually` module is planned).
- E2E: unique ports and route IDs; do not rely on parallel ExUnit cases.
- Keep fixtures aligned with current API and schema contracts.

## High-Value Coverage Areas

- `HydraSrt.RouteHandler` — route lifecycle, failover
- `HydraSrtWeb` controllers and `RealtimeChannel`
- MCP tokens and `/mcp` auth — `test/hydra_srt/db_tokens_test.exs`, `test/hydra_srt_web/controllers/token_controller_test.exs`, `test/e2e_mcp/` (HTTP protocol E2E); see [../docs/mcp.md](../docs/mcp.md)
- E2E SRT/UDP/RTP/RTMP pipelines under `test/e2e/` (RTMP client: `test/e2e/rtmp_client_pipeline_e2e_test.exs`)
- Native pipeline under `test/native_e2e/`
- Stats/analytics collectors

## References

- [../AGENTS.md](../AGENTS.md) — project guide
- [../docs/mcp.md](../docs/mcp.md) — MCP behaviour and client setup
- [test/support/](support/) — shared test helpers
- [test/e2e/](e2e/) — Elixir E2E tests
- [test/native_e2e/](native_e2e/) — native pipeline E2E
- [../Makefile](../Makefile) — `test_*` targets
- [../.github/workflows/ci.yml](../.github/workflows/ci.yml)
