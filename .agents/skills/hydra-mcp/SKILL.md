---
name: hydra-mcp
description: >-
  Query the running HydraSRT instance via MCP (routes, logs, stats, control).
  Use when the user invokes /HydraSRT or asks to inspect or control a live
  HydraSRT deployment through MCP.
disable-model-invocation: true
---

# HydraSRT MCP

Operate against a **live HydraSRT** instance through its MCP server.

## User request

The user invoked `/HydraSRT` (or an equivalent slash command) and their question follows in the same message. Treat that text as the task to complete.

## MCP server

- **Endpoint:** `http://localhost:4000/mcp` (adjust host/port to the running instance)
- **Auth:** `Authorization: Bearer <MCP token>` — dedicated MCP token from Settings → MCP tokens (not the UI session token)
- **Prerequisite:** HydraSRT must be running (`make dev` or equivalent). If MCP is unavailable, say so and ask the user to start Hydra and verify MCP client configuration.

## How to work

1. **Read tool schemas first** — inspect available MCP tool descriptors before calling.
2. **Prefer MCP over guessing** — use MCP tools for routes, sources, destinations, tags, interfaces, nodes, analytics, and logs. Do not invent IDs or statuses.
3. **Pick the smallest set of tools** — e.g. `list_routes` before `get_route`; use filters and time ranges instead of dumping everything.
4. **Mutations need confirmation** — before `create_*`, `update_*`, `delete_*`, `start_route`, `stop_route`, `restart_route`, or `switch_route_source`, summarize the planned change and ask unless the user already asked for that exact action.
5. **Time ranges** — analytics/log tools accept `window`: `last_30_min`, `last_hour`, `last_6_hour`, `last_24_hour`, or custom `from` + `to` (ISO8601). `window: live` is **not** supported; use explicit `from`/`to` for polling.
6. **Scoped IDs** — source and destination tools require `route_id` in addition to entity IDs.

## Tool domains (43 tools)

| Domain | Examples |
|--------|----------|
| Routes | `list_routes`, `get_route`, `start_route`, `stop_route`, `restart_route`, `switch_route_source` |
| Sources | `list_sources`, `get_source`, `test_source` (requires `route_id`) |
| Destinations | `list_destinations`, `get_destination` (requires `route_id`) |
| Tags | `list_tags`, `create_tag`, `update_tag`, `delete_tag` |
| Interfaces | `list_interfaces`, `list_system_interfaces`, `get_system_interface` |
| Nodes | `list_nodes`, `get_self_node`, `get_node_analytics` |
| Observability | `get_route_events`, `get_route_pipeline_logs`, `get_route_analytics`, `get_routes_status_history` |

Full catalog and contracts: [docs/mcp.md](../../../docs/mcp.md).

## Response format

- Lead with a direct answer to the user's question.
- Cite concrete data from MCP responses (route names/IDs, statuses, counts, recent log lines).
- If a tool returns `{"error": ...}` or `{"errors": ...}`, explain it plainly and suggest the next step.
- Keep output concise unless the user asked for a full dump.

## Out of scope for MCP

MCP token CRUD, backup/restore, WebSocket live push, and UI login stay on REST/UI only. Point the user to the web UI or [docs/api.md](../../../docs/api.md) if they need those.
