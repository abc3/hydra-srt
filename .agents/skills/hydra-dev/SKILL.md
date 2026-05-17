---
name: hydra-dev
description: >-
  Run HydraSRT development workflows: mix q quality gate, Elixir unit/E2E tests,
  native Rust tests, web Vitest/Playwright, and make dev. Use when the user asks
  to run tests, check code quality, start the dev server, or debug CI locally.
---

# HydraSRT Development

Actionable dev and test commands for HydraSRT. Stable reference: `AGENTS.md`, `test/AGENTS.md`.

## When to use

- Run or debug a specific test layer (Elixir, native, web)
- Pre-commit quality check (`mix q`)
- Start local dev (`make dev`)
- Reproduce CI locally (`make test_ci_local`)

## Agent behaviour

- Show the exact shell command before running it.
- Summarize pass/fail counts and duration; offer full logs on failure.
- **Elixir unit**: default `mix test` (excludes `:e2e`, `:native_e2e` via `test/test_helper.exs`).
- **Elixir E2E**: requires `E2E=true`; needs `ffmpeg` and native binary built.
- **Native E2E**: requires `NATIVE_E2E=true`.
- Do not run `make test_ci_local` unless the user asks (slow, full stack).
- Follow project standards: no `defp`, do not delete commented code.
- When creating commits, use Conventional Commits (`feat:`, `fix:`, `docs:`, etc.) per `AGENTS.md`.

## Command map

### Quality

```bash
mix q
# or: mix quality
# format --check-formatted, compile --warnings-as-errors, credo, dialyzer
```

First-time Dialyzer: `mix dialyzer` (builds PLT).

### Elixir

| Intent | Command |
|--------|---------|
| Unit (default) | `mix test` |
| One file | `mix test test/hydra_srt/route_handler_test.exs` |
| One line | `mix test test/hydra_srt/route_handler_test.exs:42` |
| E2E | `E2E=true mix test --only e2e` or `make test_e2e` |
| E2E encrypted | `E2E=true mix test --only encrypted` |
| Native E2E | `NATIVE_E2E=true mix test test/native_e2e` |

Debug env: `TRACE=true`, `SLOWEST=true`, `TEST_TIMEOUT=ms`, `E2E_DEBUG_LOGS=true` (with E2E).

### Native (Rust)

```bash
cd native && cargo test          # unit
make test_rs_native_unit
make test_rs_native_e2e          # Elixir wrapper + NATIVE_E2E=true
```

### Web

```bash
cd web_app && npm run test:unit
cd web_app && npm run test:unit:watch
cd web_app && npm run test:e2e   # Playwright; backend + native build required
```

### Aggregates

```bash
make test_all        # sequential: backend unit, e2e, native unit, web unit, web e2e
make test_ci_local   # CI-equivalent (slow)
make dev             # IEx + Phoenix; see docs/ENVS.md for env vars
```

## Natural language

| User says | Run |
|-----------|-----|
| run unit tests / backend tests | `mix test` |
| run e2e / srt e2e | `E2E=true mix test --only e2e` |
| run native tests | `cd native && cargo test` |
| run web tests | `cd web_app && npm run test:unit` |
| run playwright | `cd web_app && npm run test:e2e` |
| check quality / before commit | `mix q` |
| start dev server | `make dev` |
| like CI | `make test_ci_local` |

## Before committing (typical)

1. `mix q` — fast quality gate
2. `mix test` — Elixir unit
3. If touching routes/SRT/native: `make test_e2e` and/or `cd native && cargo test`
4. If touching UI: `cd web_app && npm run test:unit`
5. Commit with **Conventional Commits** (see `AGENTS.md` Standards): e.g. `feat: ...`, `fix: ...`, `docs: ...`, `chore: ...`

## E2E notes

- E2E uses `max_cases: 1` (shared DB + HTTP).
- `:encrypted` tests skipped if ffmpeg lacks SRT passphrase support.
- Helpers: `HydraSrt.TestSupport.E2EHelpers` — see `test/AGENTS.md`.

## References

- `AGENTS.md` — architecture, docs index
- `test/AGENTS.md` — full test matrix, support modules, tags
- `Makefile` — all `test_*` targets
- `docs/ENVS.md` — environment variables
