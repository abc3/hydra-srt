---
name: hydra-architect
description: Use when designing or evolving Hydra platform architecture across Elixir/Phoenix, SQLite, DuckDB analytics, native/Rust, and runtime boundaries.
---

# Hydra Architect

## When to use
Use this skill for architecture/design work in Hydra:
- new subsystems and major refactors,
- data model and migration strategy,
- OTP lifecycle and process boundaries,
- reliability/operability decisions,
- implementation planning for coding agents.

## Hydra-specific defaults
- Primary source of truth: `SQLite` via Ecto (`ecto_sqlite3`).
- Analytics/time-series sink: `DuckDB` (not transactional source of truth).
- Control plane: Elixir/Phoenix.
- Media/runtime work may involve native components and GStreamer.
- Prefer incremental evolution over big-bang rewrites.

## Non-negotiable principles
1. Persist domain state in SQLite; do not store authoritative entity state in GenServers.
2. Keep side effects at boundaries; business rules stay pure when possible.
3. Use `Ecto.Multi` or explicit transactions for multi-step writes.
4. Design for crash recovery and idempotency in long-running/runtime workflows.
5. Every architecture change includes test strategy and rollback path.

## Decision policy (context over dogma)
- Ash/Oban/Broadway are optional tools, not mandatory defaults.
- TDD is preferred for risky logic and regressions; proportionate rigor for small safe edits.
- Umbrella vs multi-app split is a tradeoff decision; do not force one style.

## Architecture workflow
1. Confirm scope and constraints
- Problem, success criteria, latency/reliability targets, migration risk.

2. Map current system touchpoints
- Read impacted modules, schemas, migrations, supervisors, API handlers, and tests.
- Identify SQLite tables and any DuckDB analytics coupling.

3. Propose 1-2 viable designs
- For each option: data flow, transaction boundaries, failure modes, observability, and cost.

4. Choose and document one design
- Record rationale and explicit tradeoffs.
- List invariants that must remain true.

5. Produce implementation plan
- Small, reversible steps with validation after each step.
- Include feature flag / staged rollout when risk is non-trivial.

## SQLite guidance (Hydra)
- Treat SQLite as authoritative operational state.
- Keep migrations backward-compatible when feasible.
- Avoid lock-heavy long transactions in hot paths.
- Validate constraints at DB and changeset layers.
- For backups/restore-sensitive changes, call out integrity implications explicitly.

## DuckDB guidance (Hydra)
- Use DuckDB for analytics/history, not transactional correctness.
- Writes to DuckDB should be resilient to delay/retry.
- If analytics ingestion fails, control-plane operations should remain healthy unless explicitly required otherwise.
- Keep analytics schema evolution explicit and versioned.

## OTP and runtime boundaries
- GenServers are for orchestration, caches, buffering, and lifecycle control.
- Domain truth lives in DB, not process memory.
- Define restart semantics per child and expected recovery behavior.
- Specify how pipeline/runtime restarts reconcile with persisted route/config state.

## Required outputs for architecture tasks
For substantial architecture work, produce these artifacts (keep concise):
1. `Context`: problem, constraints, non-goals.
2. `Option A/B`: tradeoffs and failure modes.
3. `Chosen design`: data model, boundaries, supervision impact.
4. `Plan`: ordered implementation steps.
5. `Validation`: tests, telemetry checks, and rollback strategy.

## Review checklist
- Clear ownership of authoritative state (SQLite vs in-memory vs DuckDB).
- Transaction boundaries are explicit and safe.
- Failure/retry/idempotency paths are defined.
- Migration and rollback path are realistic.
- Test plan covers regressions and concurrency-sensitive paths.
- Operational signals (logs/metrics) are sufficient for debugging.

## Anti-patterns to avoid
- Treating DuckDB as system-of-record.
- Hiding domain mutations in controllers/web layer.
- Long blocking work in request path when async boundary is appropriate.
- Large refactors without staged verification.
- Architecture docs with no executable plan.
