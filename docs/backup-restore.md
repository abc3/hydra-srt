# Backup and Restore System

## Overview

The Backup and Restore system allows users to create complete system backups and restore them when needed. This feature ensures data safety and provides disaster recovery capabilities for the Hydra SRT system.

## Features

The system provides two main functions:

1. **System Backup**: Create a complete binary backup of the entire system configuration
2. **System Restore**: Restore the system from a previously created backup file

## How It Works

### Backup Process

1. **User Initiates Backup**:

   - User navigates to the Settings page and clicks the "Download Backup" button
   - Frontend makes an authenticated API request to get a secure download link

2. **Backend Creates Link**:

   - Backend generates a unique session ID (UUID)
   - Session ID is stored in cache with a 5-minute expiration
   - Backend returns a download URL containing the session ID

3. **Frontend Opens Download Link**:

   - Frontend receives the URL and opens it in a new browser tab/window

4. **Backend Processes Download Request**:
   - Backend verifies the session ID is valid by checking the cache
   - If valid, the backend generates a binary backup file containing all system data
   - The session ID is deleted from cache to prevent reuse (one-time use)
   - The backup file is sent to the browser as a download with a timestamped filename

### Restore Process

1. **User Initiates Restore**:

   - User navigates to the Settings page and clicks the "Select Backup File" button
   - User selects a backup file (.backup extension) from their local system
   - A confirmation dialog appears, warning about data replacement

2. **User Confirms Restore**:

   - After confirmation, the frontend sends the backup file to the backend
   - A loading notification appears during the process

3. **Backend Processes Restore**:

   - Backend receives the binary data and deserializes it
   - The system data is completely replaced with the data from the backup
   - Backend returns a success or error message

4. **Frontend Shows Result**:
   - Frontend displays a success or error notification based on the backend response

## Security Considerations

1. **Authentication**: Only authenticated users can perform backup and restore operations
2. **Data Integrity**: Backup files contain serialized Erlang terms that maintain data integrity
3. **Secure Download**: Backup downloads use secure, time-limited, one-time-use links
4. **Confirmation**: Restore operations require explicit user confirmation to prevent accidental data loss

## Implementation Details

### Backend Components

1. **Controller**: `HydraSrtWeb.BackupController`

   - `create_backup_download_link/2`: Generates and caches a session ID for binary backup
   - `download_backup/2`: Verifies the session ID and serves the binary backup file
   - `restore/2`: Processes the uploaded backup file and restores the system

2. **Database Module**: `HydraSrt.Db`

   - `backup/0`: Creates a binary backup of all system data
   - `restore_backup/1`: Restores the system from a binary backup

3. **Router Configuration**:
   - `/api/backup/create-backup-download-link`: Authenticated endpoint to get a download link
   - `/backup/:session_id/download_backup`: Public endpoint that serves the backup file
   - `/api/restore`: Special endpoint for handling binary data uploads

### Frontend Components

1. **API Utility**: `backupApi` in `api.js`

   - `getBackupDownloadLink()`: Makes an authenticated request to get a secure download link
   - `downloadBackup()`: Gets a secure link and opens it in a new tab/window
   - `restore(file)`: Uploads a backup file to the backend for restoration

2. **UI Component**: Settings page in `Settings.jsx`
   - "Download Backup" button for creating and downloading backups
   - "Select Backup File" button for initiating the restore process
   - Confirmation dialog before performing restore
   - Notifications for operation status (loading, success, error)

## Backup File Format

The backup file is a binary file with the `.backup` extension containing serialized Erlang terms. The file represents the complete state of the Khepri database, including all routes, destinations, and system configuration.

The filename format is: `hydra-srt-MM-DD-YY-HH:MM:SS.backup` where the timestamp represents the creation time.

## Future Enhancements

Potential future enhancements for the backup and restore system:

1. **Scheduled Backups**: Automatically create backups on a schedule
2. **Backup History**: Keep a history of backups with the ability to restore from any point
3. **Selective Restore**: Allow users to select specific components to restore
4. **Cloud Storage**: Integrate with cloud storage providers for backup storage
5. **Backup Encryption**: Add encryption to backup files for additional security
