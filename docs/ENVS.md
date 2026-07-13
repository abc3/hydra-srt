# Environment Variables

All environment variables recognised by Hydra SRT, grouped by purpose.

---

## Application server

| Variable | Required | Default | Description |
|---|---|---|---|
| `PHX_SERVER` | No | — | Set to any non-empty value to start the Phoenix HTTP server (typically used in releases). |
| `PHX_HOST` | No | `localhost` (dev) / `example.com` (prod) | Public hostname used when building URLs. |
| `PORT` | No | `4000` | HTTP listen port. |
| `PHX_CHECK_ORIGIN` | No | `false` (prod) | WebSocket origin checks: unset/empty/`false`/`0`/`no` disables; `true`/`1`/`yes` uses the endpoint host; comma-separated URLs allow specific origins. Example: `http://198.51.100.10:4000,http://203.0.113.20:4000`. |
| `SECRET_KEY_BASE` | **prod only** | hardcoded in dev/test | Secret used to sign/encrypt cookies and tokens. Generate with `mix phx.gen.secret`. |
| `DEMO_DATA` | No | `false` | Enables demo bootstrap and signal generation tools: auto-creates `demo_route` (SRT source), `demo_udp_route` (UDP source), `demo_rtp_route` (RTP source), `demo_rtmp_route` (RTMP source), and `demo_rtmp-client_route` (SRT source with UDP + RTMP client destinations at `rtmp://127.0.0.1:1935/live/stream`). SRT/UDP/RTP demo routes include SRT+UDP destinations; the RTMP demo route includes SRT and RTMP destinations, publishing RTMP to `rtmp://127.0.0.1:1935/demo/routetest`. Signal generation tabs default to SRT on port 4200, UDP on 4201, RTP on 4202, and RTMP on port 1935 path `/live/test`. Requires `ffmpeg` in `PATH`; app fails to start if missing. |

---

## Authentication

| Variable | Required | Default | Description |
|---|---|---|---|
| `API_AUTH_USERNAME` | **prod** (optional in dev) | `admin` (dev) | Username for API login. |
| `API_AUTH_PASSWORD` | **prod** (optional in dev) | `password123` (dev) | Password for API login. |

---

## Database

| Variable | Required | Default | Description |
|---|---|---|---|
| `DATABASE_PATH` | **prod** (optional in dev) | `hydra_srt_dev.db` (dev) | Absolute path to the SQLite main database file. Example: `/etc/hydra_srt/hydra_srt.db`. |
| `POOL_SIZE` | No | `5` | Ecto database connection pool size. |

---

## Monitoring & metrics

| Variable | Required | Default | Description |
|---|---|---|---|
| `METRICS_SECRET` | No | — | Bearer token required to access the `/metrics` endpoint. If unset, the endpoint is unauthenticated. |
| `PROM_POLL_RATE` | No | `5000` | Interval in milliseconds between Prometheus metric polls. |
| `VICTORIA_METRICS_URL` | No | `http://127.0.0.1:8428` | VictoriaMetrics base URL for historical metrics and route events. |
| `VICTORIA_LOGS_URL` | No | `http://127.0.0.1:9428` | VictoriaLogs base URL for historical pipeline logs. |
| `SYSTEM_METRICS_HISTORY_ENABLED` | No | `true` | Enables background persistence of system telemetry samples to VictoriaMetrics. |
| `SYSTEM_METRICS_HISTORY_INTERVAL_MS` | No | `5000` | Flush interval in milliseconds for writing buffered system telemetry rows to VictoriaMetrics. |
| `HYDRA_DEFAULT_BIND_IP` | No | `127.0.0.1` | Default IP address used when binding SRT streams. |

---

## Release

| Variable | Required | Default | Description |
|---|---|---|---|
| `RELEASE_COOKIE` | No | random base64 | Erlang distribution cookie used by the release. Set explicitly for multi-node clusters or rolling restarts. |

---

## Testing

These variables are only relevant when running the test suite.

| Variable | Values | Description |
|---|---|---|
| `E2E` | `true` | Enable the E2E test suite (requires a running server). |
| `E2E_UI` | `true` | Start the Phoenix HTTP server during tests (used with E2E). |
| `E2E_HOST` | hostname | Host to connect to during E2E tests (default `127.0.0.1`). |
| `E2E_PORT` | port number | Port used for the E2E test server (default `4000`). |
| `E2E_DATABASE_PATH` | file path | Path to the SQLite DB used during E2E tests. |
| `E2E_DEBUG_LOGS` | `true` | Print full stdout/stderr from external E2E helper processes. |
| `NATIVE_E2E` | `true` | Enable native (Rust) E2E tests. |
| `CI` | `true` | Increases certain timing tolerances to reduce flakiness in CI environments. |
| `TRACE` | `true` | Print every test name as it runs (ExUnit trace mode). |
| `SLOWEST` | `true` | Print the 10 slowest tests after the suite finishes. |
| `TEST_TIMEOUT` | milliseconds | Override the per-test timeout (e.g. `TEST_TIMEOUT=10000`). |
| `MIX_TEST_PARTITION` | integer | Used by `mix test --partitions` to partition the test database filename. |
| `UNIT_DATABASE_PATH` | file path | Path to the SQLite DB used during unit tests. |
