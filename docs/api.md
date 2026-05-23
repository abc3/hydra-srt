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

### Export Routes

*   **Endpoint:** `GET /api/backup/export`
*   **Description:** Exports all routes configuration as JSON.

### Create Download Link (JSON)

*   **Endpoint:** `GET /api/backup/create-download-link`
*   **Description:** Generates a temporary link to download routes as JSON.

### Create Download Link (Binary Backup)

*   **Endpoint:** `GET /api/backup/create-backup-download-link`
*   **Description:** Generates a temporary link to download a full system backup (SQLite `.db` snapshot).
*   **Security note:** The backup contains notification settings, including Telegram bot tokens stored in the database.

### Download Backup

*   **Endpoint:** `GET /backup/:session_id/download`
*   **Description:** Downloads the JSON export (requires session ID from create link).

*   **Endpoint:** `GET /backup/:session_id/download_backup`
*   **Description:** Downloads the SQLite `.db` backup (requires session ID from create link).

### Restore Backup

*   **Endpoint:** `POST /api/restore`
*   **Description:** Restores system state from a SQLite `.db` backup snapshot.
*   **Payload:** Raw SQLite DB file bytes.

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
