# HydraSRT Backend API Documentation

This document outlines the available API endpoints for the HydraSRT backend.

## Authentication

All API requests (except `/health` and `/api/login`) require authentication via a Bearer token.
The token is obtained by logging in and should be sent in the `Authorization` header.

**Header Format:**
`Authorization: Bearer <token>`

### Health Check

*   **Endpoint:** `GET /health`
*   **Description:** Checks if the service is running.
*   **Response:** `200 OK`

### Login

*   **Endpoint:** `POST /api/login`
*   **Description:** Authenticates a user and returns a session token.
*   **Payload:**
    ```json
    {
      "login": {
        "user": "your_username",
        "password": "your_password"
      }
    }
    ```
*   **Response:**
    ```json
    {
      "token": "generated_token",
      "user": "username"
    }
    ```
*   **Response:** `401 Unauthorized`
    ```json
    {
      "error": {
        "code": "INVALID_CREDENTIALS",
        "message": "Invalid username or password"
      }
    }
    ```
*   **Response:** `400 Bad Request`
    ```json
    {
      "error": {
        "code": "INVALID_REQUEST",
        "message": "Invalid request format"
      }
    }
    ```

## Routes Management

### List Routes

*   **Endpoint:** `GET /api/routes`
*   **Description:** Retrieves a list of all configured routes.
*   **Response:**
    ```json
    {
      "data": [
        {
          "id": "route_id",
          "name": "Route Name",
          ...
        }
      ]
    }
    ```

### Create Route

*   **Endpoint:** `POST /api/routes`
*   **Description:** Creates a new route.
*   **Payload:**
    ```json
    {
      "route": {
        "name": "New Route",
        "type": "caller|listener|rendezvous",
        ...
      }
    }
    ```
*   **Response:** `201 Created` with created route data.

### Get Route

*   **Endpoint:** `GET /api/routes/:id`
*   **Description:** Retrieves details of a specific route.
*   **Response:** Route object.

### Update Route

*   **Endpoint:** `PUT /api/routes/:id`
*   **Description:** Updates an existing route.
*   **Payload:**
    ```json
    {
      "route": { ... }
    }
    ```
*   **Response:** Updated route object.

### Delete Route

*   **Endpoint:** `DELETE /api/routes/:id`
*   **Description:** Deletes a route.
*   **Response:** `204 No Content`

### Route Power Control

*   **Start Route:** `GET /api/routes/:route_id/start`
*   **Stop Route:** `GET /api/routes/:route_id/stop`
*   **Restart Route:** `GET /api/routes/:route_id/restart`

### Route Runtime Statuses

Route runtime status is exposed in route payloads via `schema_status` (fallback: `status`).

Canonical runtime statuses:

*   `starting` - route start was requested and pipeline startup is in progress.
*   `processing` - pipeline is running and processing stream data.
*   `reconnecting` - pipeline lost source continuity and is attempting to reconnect.
*   `failed` - pipeline reported a terminal failure for the current run.
*   `stopped` - route is not running.

Notes:

*   `stopping` is a UI transitional state shown while a stop request is in flight; it is not a canonical runtime status emitted by the pipeline lifecycle.
*   `started` may appear in legacy flows and should be treated as an active/running state for compatibility.

## Sources Management

### SRT Stream ID

SRT source and destination endpoints in `caller` or `rendezvous` mode accept an optional
`streamid`. HydraSRT preserves the value as an opaque string and URL-encodes it when building
the SRT connection URI. Stream ID is independent of passphrase authentication. The same `streamid`
field is accepted for an SRT caller/rendezvous destination.

Example caller source payload:

```json
{
  "source": {
    "schema": "SRT",
    "mode": "caller",
    "address": "198.51.100.20",
    "port": 4209,
    "streamid": "#!::r=channel",
    "authentication": true,
    "passphrase": "some_pass_1",
    "pbkeylen": 16
  }
}
```

**Listener sources:** SRT source endpoints in `mode=listener` may also set `streamid`. Incoming
callers must present a matching Stream ID; HydraSRT does not send this value on outgoing
connections. When `streamid` is configured and a caller sends none (or an empty value), the
connection is rejected. Stream ID checking composes with passphrase authentication: both are
enforced when configured, and neither replaces the other.

Listener sources also accept `streamid_match_mode`, which controls how the configured
`streamid` is compared to the value sent by the caller:

*   `exact` (default) - trimmed byte equality of the whole streamid string.
*   `resource` - compares the `r=` value from the Haivision access-control syntax
    `#!::u=user,r=resource,m=publish`. If the configured value is itself `#!::`-formed, its
    `r=` value is used; otherwise the configured value is compared literally as the expected
    resource. If the incoming streamid is not `#!::`-formed, the caller is rejected with
    `streamid_mismatch`; it is not silently compared as a whole string.
*   `prefix` - the incoming streamid must start with the configured value.

When `streamid` is omitted on a listener source, no Stream ID check is performed.

Example listener source payload with Stream ID:

```json
{
  "source": {
    "schema": "SRT",
    "mode": "listener",
    "localaddress": "0.0.0.0",
    "localport": 4201,
    "streamid": "studio-a",
    "streamid_match_mode": "exact",
    "authentication": true,
    "passphrase": "some_pass_1"
  }
}
```

### SRT Listener IP Access Control

SRT source endpoints in `mode=listener` can optionally limit incoming caller connections by IP address. This is a source-level stream access control feature; route control only stores and forwards the source settings to the native pipeline process.

Source fields:

*   `limit_access` - boolean switch. When `false`, saved allow/deny lists are ignored and callers are not filtered by IP.
*   `allowed_list` - JSON array of IP addresses or CIDR ranges. When non-empty and `limit_access=true`, callers must match at least one entry unless they are denied.
*   `denied_list` - JSON array of IP addresses or CIDR ranges. Denied entries take priority over allowed entries.
*   `max_callers` - optional integer, minimum 1, listener sources only. When absent, there is no limit on concurrent callers. When set, new connection attempts are rejected once the limit is reached. A listener that accepts multiple callers mixes their data into one stream, so operators usually set this to `1`.

Example source payload:

```json
{
  "source": {
    "schema": "SRT",
    "mode": "listener",
    "localaddress": "0.0.0.0",
    "localport": 4201,
    "limit_access": true,
    "allowed_list": ["10.10.0.0/16", "203.0.113.12"],
    "denied_list": ["10.10.5.20"],
    "max_callers": 1
  }
}
```

Accepted list entries are exact IPv4/IPv6 addresses or CIDR ranges, for example `127.0.0.1`, `192.0.2.0/24`, or `2001:db8::/32`.

Runtime logging:

*   Native emits structured `srt_access` events for connection attempts when the GStreamer SRT listener invokes `caller-connecting`.
*   The backend forwards those events into pipeline logs with category `srt_access`.
*   Rejected callers are logged with the caller IP and rejection reason, such as `denied_list`, `not_in_allowed_list`, `invalid_address`, `streamid_mismatch`, `streamid_missing`, or `max_callers_reached`.

Current limitation:

*   Enforcement depends on GStreamer's `srtsrc` `caller-connecting` signal. Some local GStreamer/SRT combinations do not emit that signal for ffmpeg callers unless the SRT authentication path is active, so real rejection behavior should be verified against the deployed GStreamer version before relying on it in production.

### SRT Listener Connected Callers

*   **Endpoint:** `GET /api/routes/:route_id/srt/callers`
*   **Description:** Returns the currently connected SRT callers for the route's active listener source, with live per-caller statistics enriched by the backend. The same caller data is also pushed over the realtime WebSocket stats channel.
*   **Response:**
    ```json
    {
      "data": [
        {
          "caller-address": "203.0.113.5:41234",
          "stream-id": "studio-a",
          "packet-loss-percent": 0.12,
          "retransmitted-packets-per-sec": 4.5,
          "dropped-packets-per-sec": 0.0,
          "nack-packets-per-sec": 2.1,
          "connected_at": "2026-09-03T06:45:10.123456Z",
          "duration_seconds": 127,
          "label": "Studio A uplink"
        }
      ],
      "meta": {
        "connected_callers": 1
      }
    }
    ```

Each caller entry combines pipeline metrics with backend enrichment:

*   `caller-address` - caller socket as `ip:port` (pipeline metric, kebab-case key).
*   `stream-id` - Stream ID presented by the caller. Omitted when unknown (pipeline metric, kebab-case key).
*   `packet-loss-percent`, `retransmitted-packets-per-sec`, `dropped-packets-per-sec`, `nack-packets-per-sec` - interval SRT metrics computed per caller (pipeline metrics, kebab-case keys). Value is `null` on the first stats tick when there is no previous sample.
*   `connected_at` - ISO 8601 UTC timestamp when the caller connected (backend enrichment, snake_case key).
*   `duration_seconds` - integer seconds since connection (backend enrichment, snake_case key).
*   `label` - friendly name resolved from the global caller-labels table by caller IP, or `null` when no label matches (backend enrichment, snake_case key).

### Ban SRT Caller

*   **Endpoint:** `POST /api/routes/:route_id/srt/callers/ban`
*   **Description:** Blocks a caller IP on the route's active SRT listener source by appending it to `denied_list` and setting `limit_access` to `true`. The updated endpoint configuration is persisted. The route is not restarted.
*   **Payload:**
    ```json
    {
      "ip": "203.0.113.5"
    }
    ```
*   **Response:**
    ```json
    {
      "data": {
        "endpoint_id": "endpoint_uuid",
        "limit_access": true,
        "denied_list": ["10.10.5.20", "203.0.113.5"]
      }
    }
    ```
*   **Status codes:** `404 Not Found` when the route has no active SRT listener source; `422 Unprocessable Entity` for a malformed IP address.

SRT offers no API to disconnect an already connected caller. A ban takes effect on the caller's
next connection attempt; any current session continues until the caller disconnects on its own.

### Caller Labels

Caller labels are installation-wide tags for known client IP addresses. They are not scoped to
individual routes. When per-caller stats are enriched, the backend resolves `label` by caller IP
using these rules: an exact `address` match wins over a CIDR entry, and among CIDR entries the
longest matching prefix wins.

*   **Endpoint:** `GET /api/caller-labels`
*   **Description:** Lists all caller labels.
*   **Response:**
    ```json
    {
      "data": [
        {
          "id": "label_uuid",
          "address": "203.0.113.5",
          "label": "Studio A uplink",
          "note": "Primary contribution feed",
          "inserted_at": "2026-09-01T10:00:00.000000Z",
          "updated_at": "2026-09-01T10:00:00.000000Z"
        }
      ]
    }
    ```

*   **Endpoint:** `POST /api/caller-labels`
*   **Description:** Creates a caller label.
*   **Payload:**
    ```json
    {
      "caller_label": {
        "address": "203.0.113.0/24",
        "label": "Studio A network",
        "note": "Optional note"
      }
    }
    ```
*   **Response:** `201 Created` with the created label in `data`.

*   **Endpoint:** `PATCH /api/caller-labels/:id`
*   **Description:** Updates a caller label.
*   **Payload:**
    ```json
    {
      "caller_label": {
        "label": "Updated label",
        "note": "Updated note"
      }
    }
    ```
*   **Response:** `200 OK` with the updated label in `data`.

*   **Endpoint:** `DELETE /api/caller-labels/:id`
*   **Description:** Deletes a caller label.
*   **Response:** `204 No Content`

Label fields:

*   `address` - plain IP address or CIDR range. Must be unique across all labels.
*   `label` - display name shown in connected-caller views.
*   `note` - optional free-text note.

## Destinations Management

### List Destinations

*   **Endpoint:** `GET /api/routes/:route_id/destinations`
*   **Description:** Retrieves all destinations for a specific route.

### Create Destination

*   **Endpoint:** `POST /api/routes/:route_id/destinations`
*   **Description:** Adds a new destination to a route.
*   **Payload:**
    ```json
    {
      "destination": { ... }
    }
    ```

### Get Destination

*   **Endpoint:** `GET /api/routes/:route_id/destinations/:dest_id`
*   **Description:** Retrieves details of a specific destination.

### Update Destination

*   **Endpoint:** `PUT /api/routes/:route_id/destinations/:dest_id`
*   **Description:** Updates a destination.

### Delete Destination

*   **Endpoint:** `DELETE /api/routes/:route_id/destinations/:dest_id`
*   **Description:** Removes a destination from a route.

## Notifications

### Get Telegram Settings

*   **Endpoint:** `GET /api/notifications/telegram`
*   **Description:** Returns Telegram notification settings with masked token fields.

### Update Telegram Settings

*   **Endpoint:** `PUT /api/notifications/telegram`
*   **Description:** Creates or updates Telegram notification settings.
*   **Payload:**
    ```json
    {
      "notification": {
        "enabled": true,
        "bot_token": "123456:ABCDEF",
        "chat_id": "-1001234567890"
      }
    }
    ```

### Send Telegram Test Notification

*   **Endpoint:** `POST /api/notifications/telegram/test`
*   **Description:** Sends a test Telegram notification.
*   **Payload (optional):** You can pass unsaved form values under `notification` to test credentials before saving.
    ```json
    {
      "notification": {
        "enabled": true,
        "bot_token": "123456:ABCDEF",
        "chat_id": "-1001234567890"
      }
    }
    ```

## System & Diagnostics

### List Pipelines

*   **Endpoint:** `GET /api/system/pipelines`
*   **Description:** Lists active pipeline processes (simple view).

### List Pipelines Detailed

*   **Endpoint:** `GET /api/system/pipelines/detailed`
*   **Description:** Lists active pipeline processes with detailed information.

### Kill Pipeline

*   **Endpoint:** `POST /api/system/pipelines/:pid/kill`
*   **Description:** Kills a specific pipeline process.

### Nodes (Cluster Info)

*   **Endpoint:** `GET /api/nodes`
*   **Description:** Lists all nodes in the cluster with status and resource usage (CPU, RAM, Load Average).

*   **Endpoint:** `GET /api/nodes/:id`
*   **Description:** detailed information for a specific node.

## Backup & Restore

### Routes Backup

*   **Endpoint:** `GET /api/backup/routes`
*   **Description:** Downloads a versioned `hydra-srt-routes-<ddMMyyHHmm>.json` file containing portable route, source, destination, and tag configuration.

*   **Endpoint:** `POST /api/backup/routes`
*   **Description:** Validates and imports a routes backup. A successful import replaces all existing routes.
*   **Payload:** Routes backup JSON.

Routes backups include SRT passphrases. Treat backup files as sensitive.

### Download Database Backup

*   **Endpoint:** `GET /api/backup/full`
*   **Description:** Downloads a consistent SQLite `.db` snapshot for disaster recovery.
*   **Response Content-Type:** `application/octet-stream`
*   **Security note:** The database contains route passphrases, notification credentials, tokens, and other system configuration.

### Restore Backup

*   **Endpoint:** `POST /api/backup/full/restore`
*   **Description:** Validates and restores system state from a compatible SQLite `.db` snapshot. Active routes are stopped and restarted from the restored configuration. If restore fails after the database swap, the previous database is restored.
*   **Payload:** Raw SQLite DB file bytes.
*   **Compatibility:** The backup must have the same database migration versions as the running Gateway.

## MCP Tokens

MCP tokens are long-lived API keys used to authenticate MCP clients against the `/mcp` endpoint. They are separate from login session tokens returned by `POST /api/login`.

Manage tokens in the UI at `/settings/tokens` or via the REST API below. Session authentication is required for token management endpoints.

### List Tokens

*   **Endpoint:** `GET /api/tokens`
*   **Description:** Returns configured MCP tokens. Raw token values are never included in list responses.
*   **Response:**
    ```json
    {
      "data": [
        {
          "id": "uuid",
          "name": "cursor",
          "inserted_at": "2026-05-23T12:00:00.000000Z",
          "updated_at": "2026-05-23T12:00:00.000000Z"
        }
      ]
    }
    ```

### Create Token

*   **Endpoint:** `POST /api/tokens`
*   **Description:** Creates a named MCP token. The raw token value is returned only in this response.
*   **Payload:**
    ```json
    {
      "token": {
        "name": "cursor"
      }
    }
    ```
*   **Response:**
    ```json
    {
      "data": {
        "id": "uuid",
        "name": "cursor",
        "token": "generated_mcp_token",
        "inserted_at": "2026-05-23T12:00:00.000000Z",
        "updated_at": "2026-05-23T12:00:00.000000Z"
      }
    }
    ```

### Update Token

*   **Endpoint:** `PUT /api/tokens/:id`
*   **Description:** Renames an MCP token. Token values cannot be changed; create a new token instead.
*   **Payload:**
    ```json
    {
      "token": {
        "name": "new name"
      }
    }
    ```

### Delete Token

*   **Endpoint:** `DELETE /api/tokens/:id`
*   **Description:** Revokes an MCP token immediately.

## MCP Endpoint

*   **Endpoint:** `/mcp`
*   **Description:** Streamable HTTP transport for the HydraSRT MCP server.
*   **Authentication:** Requires an MCP token (not a login session token):
    `Authorization: Bearer <mcp_token>`
*   **Unauthorized responses:** `401` with `WWW-Authenticate: Bearer`
*   **Cursor example config:**
    ```json
    {
      "mcpServers": {
        "hydrasrt": {
          "url": "http://localhost:4000/mcp",
          "headers": {
            "Authorization": "Bearer YOUR_MCP_TOKEN"
          }
        }
      }
    }
    ```
