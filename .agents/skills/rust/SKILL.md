---
name: rust
description: Use this skill for Rust development in this repo: design, implementation, debugging, performance work, and reliable testing.
---

# Rust Skill

## When to use
Use for any task touching Rust code, Cargo, clippy, unsafe blocks, async runtime, or benchmarks.

## Workflow
1. Read module boundaries and trait contracts first.
2. Make the smallest safe change that solves the issue.
3. Prefer clear ownership/lifetime design over complex workarounds.
4. Add or update tests for behavior changes.
5. Validate with fmt, clippy, and tests.

## Repo commands
- Format: `cargo fmt --all`
- Lints: `cargo clippy --all-targets --all-features -- -D warnings`
- Tests: `cargo test --all`
- Check quickly: `cargo check --all-targets --all-features`

## Design rules
- Favor enums and pattern matching for state machines.
- Use `Result` with domain-specific errors; avoid `unwrap()` in production paths.
- Keep public API minimal and documented.
- Prefer iterators and zero-copy paths when it keeps readability acceptable.

## Async and Concurrency
- Never block async executors with sync I/O or long CPU tasks.
- Use cancellation-aware patterns and explicit timeouts.
- Protect shared mutable state with clear ownership or narrow lock scopes.

## Unsafe code
- Keep unsafe blocks tiny and documented with invariants.
- Add tests specifically covering invariant boundaries.
- Prefer safe wrappers exposing safe API to callers.

## Testing and quality
- Unit tests for logic, integration tests for module interaction.
- Add regression tests for bug fixes.
- For perf-sensitive paths, include criterion or reproducible benchmark notes.

## PR checklist
- `fmt`, `clippy`, `test` are clean.
- No hidden panic paths in non-test code.
- Error messages provide actionable context.
- Concurrency behavior has explicit assumptions.
