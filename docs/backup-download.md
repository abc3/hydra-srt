# Backup Download Feature

## Overview

The Backup Download feature allows users to download a JSON backup of all routes and their destinations from the Hydra SRT system. This document explains how the feature works, its security considerations, and implementation details.

## How It Works

The backup download process uses a time-limited, one-time-use link to ensure that only authenticated users can download backups while avoiding authentication issues with direct file downloads.

### Process Flow

1. **User Initiates Download**:

   - User navigates to the Settings page and selects the "Routes" tab
   - User clicks the "Export Routes as JSON" button
   - Frontend makes an authenticated API request to get a download link

2. **Backend Creates Link**:

   - Backend generates a unique session ID (UUID)
   - Session ID is stored in cache with a 5-minute expiration
   - Backend returns a download URL containing the session ID

3. **Frontend Opens Download Link**:

   - Frontend receives the URL and opens it in a new browser tab/window

4. **Backend Processes Download Request**:

   - Backend verifies the session ID is valid by checking the cache
   - If valid, the backend generates the backup file (JSON of all routes with destinations)
   - The session ID is deleted from cache to prevent reuse (one-time use)
   - The backup file is sent to the browser as a download with a timestamped filename

5. **Security Fallbacks**:
   - If the session ID is invalid or expired, a 403 Forbidden error is returned
   - The download link expires after 5 minutes if not used

## Security Considerations

This approach addresses several security concerns:

1. **Authentication**: Only authenticated users can request a download link
2. **Link Security**: The download link contains a random UUID that is nearly impossible to guess
3. **Time Limitation**: Links expire after 5 minutes
4. **One-Time Use**: Each link can only be used once
5. **No Authentication Leakage**: The download process doesn't expose authentication tokens in URLs

## Implementation Details

### Backend Components

1. **Controller**: `HydraSrtWeb.BackupController`

   - `create_download_link/2`: Generates and caches a session ID, returns a download link
   - `download/2`: Verifies the session ID and serves the backup file with a timestamped filename

2. **Router Configuration**:

   - `/api/backup/create-download-link`: Authenticated endpoint to get a download link
   - `/backup/:session_id/download`: Public endpoint that serves the file after verifying the session ID

3. **Caching**:
   - Uses `Cachex` to store session IDs with a TTL of 5 minutes
   - Cache key format: `"backup_session:#{session_id}"`

### Frontend Components

1. **API Utility**: `backupApi` in `api.js`

   - `getDownloadLink()`: Makes an authenticated request to get a secure download link
   - `download()`: Gets a secure link and opens it in a new tab/window

2. **UI Component**: "Export Routes as JSON" button in `Settings.jsx`
   - Located in the "Routes" tab of the Settings page
   - Calls `backupApi.download()` when clicked
   - Shows success/error messages to the user

## Data Format

The downloaded backup file is a JSON file containing all routes with their destinations. The file is named `hydra-routes-MM-DD-YY-HH:MM:SS.json` (with a timestamp) and has the following structure:

```json
[
  {
    "id": "route-uuid",
    "name": "Route Name",
    "enabled": true,
    "status": "started",
    "created_at": "2023-01-01T00:00:00Z",
    "updated_at": "2023-01-02T00:00:00Z",
    "destinations": [
      {
        "id": "destination-uuid",
        "route_id": "route-uuid",
        "name": "Destination Name",
        "enabled": true,
        "created_at": "2023-01-01T00:00:00Z",
        "updated_at": "2023-01-02T00:00:00Z"
      }
    ]
  }
]
```

## Future Enhancements

Potential future enhancements for the backup feature:

1. **Scheduled Backups**: Automatically create backups on a schedule
2. **Backup History**: Keep a history of backups with the ability to restore from any point
3. **Selective Backup**: Allow users to select specific routes to back up
4. **Different Formats**: Support additional formats like YAML or CSV
