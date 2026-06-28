---
name: elixir
description: Use this skill for Elixir/Phoenix development in this repo: implementing features, refactors, debugging, tests, Ecto changes, and production-safe fixes.
---

# Elixir Skill

## When to use
Use for any task touching Elixir, Phoenix, Ecto, Mix, OTP, or ExUnit.

## Workflow
1. Read context first: routes, schema, context modules, and related tests.
2. Keep business logic in contexts, not in controllers/channels/live views.
3. Prefer small pure functions and explicit pattern matching.
4. Prefer bracket access (`map[:key]`) for map reads in app code. Do not use `Map.get/2`. Use `Map.get/3` only when an explicit default value is required.
5. Add `@spec` for every function (`def`/`defp`).
6. If a `@spec` becomes hard to read, introduce named custom types (`@type`, `@opaque`) and reuse them in specs.
7. Add or update tests with each behavior change.
8. Run targeted tests first, then broader suite if needed.

## Repo commands
- Format: `mix format`
- Compile with warnings: `mix compile --warnings-as-errors`
- Run tests: `mix test`
- Run specific test file: `mix test path/to/test_file.exs`
- Run one test line: `mix test path/to/test_file.exs:123`

## Ecto and DB
- Keep schema constraints mirrored in changesets (`validate_required`, `unique_constraint`, `foreign_key_constraint`).
- Prefer explicit preload strategy; avoid hidden N+1 queries.
- For migrations: make them reversible and safe for existing data.

## OTP and Concurrency
- Keep GenServer state minimal and explicit.
- Avoid blocking calls in server callbacks.
- Use `Task.Supervisor` for isolated async work.
- Add timeouts and backpressure where needed.

## Time durations (milliseconds)
Many APIs in this repo take or store durations in **milliseconds** (`Process.send_after/3`, `:inet.setopts/2` `send_timeout`, Cachex TTL, `Application.get_env/3` defaults, test `assert_receive` timeouts, etc.).

Prefer **`:timer`** over raw integer literals so the unit is obvious:

```elixir
# Good
@default_interval_ms :timer.seconds(30)
@recv_timeout :timer.seconds(10)
Process.send_after(self(), :tick, :timer.seconds(5))
config :app, ttl_ms: Env.get_integer("TTL_MS", :timer.minutes(5))

# Avoid (unless the value is not a duration, e.g. bytes or a port)
@default_interval_ms 30_000
send_timeout: 10_000
```

Use `:timer.seconds/1`, `:timer.minutes/1`, or `:timer.hours/1` as appropriate. `:timer` returns milliseconds. Existing examples: `HydraSrt.Auth` (`:timer.minutes(5)`), `HydraSrt.Stats.Cleaner` (`:timer.hours(1)`), RTMP config in `config/runtime.exs`.

Do **not** use `:timer` for non-duration numbers (byte counts, port numbers, numeric limits).

## Phoenix
- Controllers should orchestrate, not own domain logic.
- Keep params validation close to boundaries.
- Return consistent error payloads and status codes.

## Testing standards
- Cover happy path, validation failures, and edge cases.
- Use factories/builders instead of large inline fixtures.
- Assert behavior and observable side effects, not implementation details.

## PR checklist
- Code formatted and compiles without warnings.
- New/changed behavior has tests.
- No obvious N+1 or unbounded process growth.
- Errors are actionable and structured.
