/**
 * API service for making authenticated requests to the backend
 */
import { authFetch } from './auth';
import { API_BASE_URL } from './constants';

// System Pipelines API
export const systemPipelinesApi = {
  // Get all pipeline processes
  getAll: async () => {
    const response = await authFetch('/api/system/pipelines');
    return response.json();
  },
  
  // Get detailed pipeline information
  getDetailed: async () => {
    const response = await authFetch('/api/system/pipelines/detailed');
    return response.json();
  },
  
  // Kill a pipeline process
  kill: async (pid) => {
    const response = await authFetch(`/api/system/pipelines/${pid}/kill`, {
      method: 'POST',
    });
    return response.json();
  },
};

// Nodes API
export const nodesApi = {
  // Get all nodes
  getAll: async () => {
    const response = await authFetch('/api/nodes');
    return response.json();
  },
  
  // Get a single node by ID
  getById: async (id) => {
    const response = await authFetch(`/api/nodes/${id}`);
    return response.json();
  },
};

// Routes API
export const routesApi = {
  // Get all routes
  getAll: async () => {
    const response = await authFetch('/api/routes');
    return response.json();
  },

  // Get a single route by ID
  getById: async (id) => {
    const response = await authFetch(`/api/routes/${id}`);
    return response.json();
  },

  // Create a new route
  create: async (routeData) => {
    const response = await authFetch('/api/routes', {
      method: 'POST',
      body: JSON.stringify({ route: routeData }),
    });
    return response.json();
  },

  // Update a route
  update: async (id, routeData) => {
    const response = await authFetch(`/api/routes/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ route: routeData }),
    });
    return response.json();
  },

  // Delete a route
  delete: async (id) => {
    const response = await authFetch(`/api/routes/${id}`, {
      method: 'DELETE',
    });
    // Check if response has content before parsing as JSON
    const contentType = response.headers.get("content-type");
    if (contentType && contentType.includes("application/json")) {
      return response.json();
    }
    return { success: true };
  },

  // Start a route
  start: async (id) => {
    const response = await authFetch(`/api/routes/${id}/start`);
    return response.json();
  },

  // Stop a route
  stop: async (id) => {
    const response = await authFetch(`/api/routes/${id}/stop`);
    return response.json();
  },

  // Restart a route
  restart: async (id) => {
    const response = await authFetch(`/api/routes/${id}/restart`);
    return response.json();
  },
};

export const backupApi = {
  export: async () => {
    const response = await authFetch('/api/backup/export');
    return response.json();
  },
  
  getDownloadLink: async () => {
    const response = await authFetch('/api/backup/create-download-link');
    return response.json();
  },
  
  getBackupDownloadLink: async () => {
    const response = await authFetch('/api/backup/create-backup-download-link');
    return response.json();
  },
  
  download: async () => {
    try {
      const { download_link } = await backupApi.getDownloadLink();
      
      window.open(`${API_BASE_URL}${download_link}`, '_blank');
      return true;
    } catch (error) {
      console.error('Error downloading backup:', error);
      throw error;
    }
  },
  
  downloadBackup: async () => {
    try {
      const { download_link } = await backupApi.getBackupDownloadLink();
      
      window.open(`${API_BASE_URL}${download_link}`, '_blank');
      return true;
    } catch (error) {
      console.error('Error downloading backup:', error);
      throw error;
    }
  },
  
  restore: async (file) => {
    try {
      // Read the file as an ArrayBuffer
      const arrayBuffer = await file.arrayBuffer();
      
      // Convert ArrayBuffer to Blob with the correct MIME type
      const blob = new Blob([arrayBuffer], { type: 'application/octet-stream' });
      
      console.log('Sending file as binary data with Content-Type: application/octet-stream');
      const response = await authFetch('/api/restore', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/octet-stream',
        },
        body: blob,
      });
      
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || 'Failed to restore backup');
      }
      
      return response.json();
    } catch (error) {
      console.error('Error in restore API call:', error);
      throw error;
    }
  },
};

// Destinations API
export const destinationsApi = {
  // Get all destinations for a route
  getAll: async (routeId) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations`);
    return response.json();
  },

  // Get a single destination by ID
  getById: async (routeId, destId) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations/${destId}`);
    return response.json();
  },

  // Create a new destination
  create: async (routeId, destData) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations`, {
      method: 'POST',
      body: JSON.stringify({ destination: destData }),
    });
    return response.json();
  },

  // Update a destination
  update: async (routeId, destId, destData) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'PUT',
      body: JSON.stringify({ destination: destData }),
    });
    return response.json();
  },

  // Delete a destination
  delete: async (routeId, destId) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'DELETE',
    });
    // Check if response has content before parsing as JSON
    const contentType = response.headers.get("content-type");
    if (contentType && contentType.includes("application/json")) {
      return response.json();
    }
    return { success: true };
  },
}; 