# AGENTS.md - HydraSRT Guide

## Intent

HydraSRT is an open-source SRT routing platform. The Elixir layer manages routes, configuration, and the REST/WebSocket API. The Rust/GStreamer pipeline runs as an isolated native process for media processing. The React UI (`web_app/`) talks to the backend over HTTP.

## Runtime Baseline

- Elixir `~> 1.18`
- OTP `27+` (CI baseline: Elixir 1.18.4, OTP 27.3 — see `.github/workflows/ci.yml`)
- Rust toolchain for `native/`

## Commands

| Task | Command |
|------|---------|
| First-time setup | `mix setup` |
| Local dev server | `make dev` (env vars: `docs/ENVS.md`) |
| Code quality gate | `mix q` or `mix quality` |
| Backend unit tests | `mix test` |
| Full test matrix | See `test/AGENTS.md` |
| CI-equivalent local run | `make test_ci_local` |
| Makefile targets | `make help` |

### Quality (`mix q`)

Runs, in order: format check, compile with warnings as errors, Credo, Dialyzer.

One-time Dialyzer setup (if PLT is missing):

```bash
mix dialyzer
```

## Architecture Snapshot

Three layers:

1. **Management & control (Elixir)** — `HydraSrt.Application`, `HydraSrt.RouteHandler`, `HydraSrt.RoutesSupervisor`, Ecto/SQLite for config state.
2. **Streaming (Rust + GStreamer)** — `native/` builds `priv/native/hydra_srt_pipeline`; isolated from the BEAM for stability.
3. **API & UI** — `HydraSrtWeb` (Phoenix), `web_app/` (Vite + React).

```mermaid
flowchart LR
  UI[web_app React] --> API[HydraSrtWeb REST]
  API --> Control[HydraSrt Elixir]
  Control --> Native[Rust GStreamer pipeline]
```

## Standards

- Do not delete commented code (see `.cursorrules`).
- Do not use private functions (`defp`) in Elixir.
- In tests: use unique ports/IDs; avoid `Process.sleep/1` where a poll condition exists (see `test/AGENTS.md`).

## Testing

Unit tests run by default; E2E and native E2E are opt-in via tags and env vars. Full matrix, support modules, and debug flags: **`test/AGENTS.md`**.

## Documentation

| Document | Purpose |
|----------|---------|
| [docs/README.md](docs/README.md) | Documentation index |
| [docs/api.md](docs/api.md) | REST API |
| [docs/ENVS.md](docs/ENVS.md) | Environment variables |
| [docs/metrics-architecture.md](docs/metrics-architecture.md) | Metrics collection and export |
| [docs/backup-download.md](docs/backup-download.md) | Routes backup download |
| [docs/backup-restore.md](docs/backup-restore.md) | System backup and restore |
| [README.md](README.md) | Project overview |
| [test/AGENTS.md](test/AGENTS.md) | Test suites and helpers |

## References

- [Makefile](Makefile) — dev and test targets
- [.github/workflows/ci.yml](.github/workflows/ci.yml) — CI jobs
- [test/AGENTS.md](test/AGENTS.md) — how to run all test layers
