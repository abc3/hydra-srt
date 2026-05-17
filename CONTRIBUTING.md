# Contributing to HydraSRT

## Getting Started

Read:

- [docs/architecture.md](docs/architecture.md) - runtime architecture
- [docs/development.md](docs/development.md) - setup and deployment

## Development Workflow

1. Fork and clone the repository.
2. Set up the project with [docs/development.md](docs/development.md).
3. Create a branch.
4. Make the change.
5. Run `mix q`.
6. Run the relevant tests.
7. Open a pull request.

## Coding Standards

### General

- **Do not delete commented code**
- **Do not use private functions** (`defp`) in Elixir modules
- Add tests for behavior changes

### Testing

- Use unique ports and route IDs in tests
- Avoid `Process.sleep/1` where a condition can be polled

### Commit Messages

Use Conventional Commits:

```
type(scope): subject in imperative mood
```

- **Type** (lowercase): `feat`, `fix`, `docs`, `chore`, `test`, `refactor`, `perf`, `ci`
- **Scope** (optional): `api`, `ui`, `native`, etc.
- **Subject**: Imperative mood, concise description

#### Examples

```
feat: add route status history endpoint
fix: make username and password configurable in development
docs: update architecture overview
chore: comment out npm watcher for dev
test(e2e): add encrypted SRT failover test
refactor(native): simplify pipeline error handling
```

Keep the subject line short. Put context in the body when needed.

## Quality Gate

```bash
mix q
```

Runs:
1. Format check (`mix format --check-formatted`)
2. Compile with warnings as errors
3. Credo (static analysis)
4. Dialyzer (type checking)

### One-Time Dialyzer Setup

If the PLT is missing:

```bash
mix dialyzer
```

## Running Tests

### Quick Test (Unit Tests Only)

```bash
mix test
```

### Full Test Matrix

```bash
mix test
E2E=true mix test --only e2e
cd native && cargo test
cd web_app && npm run test:unit
cd web_app && npm run test:e2e
```

CI-equivalent local run:

```bash
make test_ci_local
```

## Pull Request Guidelines

- Run `mix q`
- Run relevant tests
- Include tests for behavior changes
- Update documentation if you change behavior or add features
- Reference any related issues in the PR description
- Keep PRs focused
