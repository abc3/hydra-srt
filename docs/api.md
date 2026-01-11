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

### Download Backup

*   **Endpoint:** `GET /backup/:session_id/download`
*   **Description:** Downloads the JSON export (requires session ID from create link).

*   **Endpoint:** `GET /backup/:session_id/download_backup`
*   **Description:** Downloads the SQLite `.db` backup (requires session ID from create link).

### Restore Backup

*   **Endpoint:** `POST /api/restore`
*   **Description:** Restores system state from a SQLite `.db` backup snapshot.
*   **Payload:** Raw SQLite DB file bytes.
