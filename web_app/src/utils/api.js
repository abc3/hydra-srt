/**
 * API service for making authenticated requests to the backend
 */
import { authFetch } from './auth';
import { API_BASE_URL } from './constants';

const publicFetch = async (url, options = {}) => {
  const fullUrl = url.startsWith('http') ? url : `${API_BASE_URL}${url}`;
  return fetch(fullUrl, options);
};

const parseJsonResponse = async (response) => {
  const contentType = response.headers.get('content-type');

  if (!contentType || !contentType.includes('application/json')) {
    return null;
  }

  return response.json();
};

const throwApiErrorIfNeeded = async (response, fallbackMessage) => {
  if (response.ok) {
    return;
  }

  const payload = await parseJsonResponse(response);
  const message =
    payload?.error ||
    payload?.message ||
    (payload?.errors ? 'Validation failed' : null) ||
    fallbackMessage;
  const error = new Error(message);
  error.status = response.status;
  error.payload = payload;
  error.errors = payload?.errors;
  throw error;
};

const requestJson = async (url, options = {}, fallbackMessage = 'Request failed') => {
  const response = await authFetch(url, options);
  await throwApiErrorIfNeeded(response, fallbackMessage);
  return response.json();
};

const requestOptionalJson = async (url, options = {}, fallbackMessage = 'Request failed') => {
  const response = await authFetch(url, options);
  await throwApiErrorIfNeeded(response, fallbackMessage);
  const payload = await parseJsonResponse(response);
  return payload ?? { success: true };
};

const requestPublicJson = async (url, options = {}, fallbackMessage = 'Request failed') => {
  const response = await publicFetch(url, options);
  await throwApiErrorIfNeeded(response, fallbackMessage);
  return response.json();
};

export const initApi = {
  get: async () => requestPublicJson('/api/init', {}, 'Failed to load app init payload'),
};

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

export const signalGenerationApi = {
  status: async () => requestJson('/api/system/signal-generation', {}, 'Failed to load signal generation status'),

  configure: async ({ host, port }) => requestJson('/api/system/signal-generation', {
    method: 'PUT',
    body: JSON.stringify({ host, port }),
  }, 'Failed to save signal generation settings'),

  start: async () => requestJson('/api/system/signal-generation/start', {
    method: 'POST',
  }, 'Failed to start signal generation'),

  stop: async () => requestJson('/api/system/signal-generation/stop', {
    method: 'POST',
  }, 'Failed to stop signal generation'),
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

  getAnalytics: async (id, params = {}) => {
    const query = new URLSearchParams();

    Object.entries(params).forEach(([key, value]) => {
      if (value === undefined || value === null || value === '') {
        return;
      }

      query.set(key, value);
    });

    const querySuffix = query.toString().length > 0 ? `?${query.toString()}` : '';
    const response = await authFetch(`/api/nodes/${encodeURIComponent(id)}/analytics${querySuffix}`);
    return response.json();
  },
};

// Routes API
export const routesApi = {
  // Get all routes
  getAll: async (params = {}) => {
    const query = new URLSearchParams();

    Object.entries(params).forEach(([key, value]) => {
      if (value === undefined || value === null || value === '') {
        return;
      }

      query.set(key, value);
    });

    const querySuffix = query.toString().length > 0 ? `?${query.toString()}` : '';
    const response = await authFetch(`/api/routes${querySuffix}`);
    return response.json();
  },

  // Get a single route by ID
  getById: async (id) => {
    const response = await authFetch(`/api/routes/${id}`);
    return response.json();
  },

  // Get route analytics time-series
  getAnalytics: async (id, params = {}) => {
    const query = new URLSearchParams();

    Object.entries(params).forEach(([key, value]) => {
      if (value === undefined || value === null || value === '') {
        return;
      }

      query.set(key, value);
    });

    const querySuffix = query.toString().length > 0 ? `?${query.toString()}` : '';
    const response = await authFetch(`/api/routes/${id}/analytics${querySuffix}`);
    return response.json();
  },

  getEvents: async (id, params = {}) => {
    const query = new URLSearchParams();

    Object.entries(params).forEach(([key, value]) => {
      if (value === undefined || value === null || value === '') {
        return;
      }

      query.set(key, value);
    });

    const querySuffix = query.toString().length > 0 ? `?${query.toString()}` : '';
    const response = await authFetch(`/api/routes/${id}/events${querySuffix}`);
    return response.json();
  },

  // Create a new route
  create: async (routeData) => {
    return requestJson('/api/routes', {
      method: 'POST',
      body: JSON.stringify({ route: routeData }),
    }, 'Failed to create route');
  },

  // Update a route
  update: async (id, routeData) => {
    return requestJson(`/api/routes/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ route: routeData }),
    }, 'Failed to update route');
  },

  // Delete a route
  delete: async (id) => {
    return requestOptionalJson(`/api/routes/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete route');
  },

  // Start a route
  start: async (id) => {
    return requestJson(`/api/routes/${id}/start`, {}, 'Failed to start route');
  },

  // Stop a route
  stop: async (id) => {
    return requestJson(`/api/routes/${id}/stop`, {}, 'Failed to stop route');
  },

  // Restart a route
  restart: async (id) => {
    return requestJson(`/api/routes/${id}/restart`, {}, 'Failed to restart route');
  },

  switchSource: async (id, sourceId) => {
    return requestJson(`/api/routes/${id}/switch-source`, {
      method: 'POST',
      body: JSON.stringify({ source_id: sourceId }),
    }, 'Failed to switch source');
  },

  // Test a route source with ffprobe
  testSource: async (routeData) => {
    const response = await authFetch('/api/routes/test-source', {
      method: 'POST',
      body: JSON.stringify({ route: routeData }),
    });

    const data = await response.json();

    if (!response.ok) {
      throw new Error(data.error || 'Failed to test source');
    }

    return data;
  },
};

export const sourcesApi = {
  list: async (routeId) => {
    const response = await authFetch(`/api/routes/${routeId}/sources`);
    return response.json();
  },

  get: async (routeId, id) => {
    const response = await authFetch(`/api/routes/${routeId}/sources/${id}`);
    return response.json();
  },

  create: async (routeId, sourceData) => {
    return requestJson(`/api/routes/${routeId}/sources`, {
      method: 'POST',
      body: JSON.stringify({ source: sourceData }),
    }, 'Failed to create source');
  },

  update: async (routeId, id, sourceData) => {
    return requestJson(`/api/routes/${routeId}/sources/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ source: sourceData }),
    }, 'Failed to update source');
  },

  delete: async (routeId, id) => {
    return requestOptionalJson(`/api/routes/${routeId}/sources/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete source');
  },

  reorder: async (routeId, sourceIds) => {
    return requestJson(`/api/routes/${routeId}/sources/reorder`, {
      method: 'POST',
      body: JSON.stringify({ source_ids: sourceIds }),
    }, 'Failed to reorder sources');
  },

  test: async (routeId, id) => {
    const response = await authFetch(`/api/routes/${routeId}/sources/${id}/test`, {
      method: 'POST',
    });
    return response.json();
  },
};

// Interfaces API
export const interfacesApi = {
  getAll: async () => {
    const response = await authFetch('/api/interfaces');
    return response.json();
  },

  getById: async (id) => {
    const response = await authFetch(`/api/interfaces/${id}`);
    return response.json();
  },

  create: async (interfaceData) => {
    const response = await authFetch('/api/interfaces', {
      method: 'POST',
      body: JSON.stringify({ interface: interfaceData }),
    });
    return response.json();
  },

  update: async (id, interfaceData) => {
    const response = await authFetch(`/api/interfaces/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ interface: interfaceData }),
    });
    return response.json();
  },

  delete: async (id) => {
    const response = await authFetch(`/api/interfaces/${id}`, {
      method: 'DELETE',
    });
    const contentType = response.headers.get("content-type");
    if (contentType && contentType.includes("application/json")) {
      return response.json();
    }
    return { success: true };
  },

  getSystemInterfaces: async () => {
    const response = await authFetch('/api/interfaces/system');
    return response.json();
  },

  getSystemRaw: async () => {
    const response = await authFetch('/api/interfaces/system/raw');
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

// Tags API
export const tagsApi = {
  // Get all unique tag names used across routes (compat for existing selectors)
  getAll: async () => {
    const response = await authFetch('/api/tags');
    const payload = await response.json();
    const list = Array.isArray(payload?.data) ? payload.data : [];
    return { data: list.map((tag) => tag?.name).filter(Boolean) };
  },

  list: async () => {
    const response = await authFetch('/api/tags');
    return response.json();
  },

  create: async (tagData) => {
    return requestJson('/api/tags', {
      method: 'POST',
      body: JSON.stringify({ tag: tagData }),
    }, 'Failed to create tag');
  },

  update: async (id, tagData) => {
    return requestJson(`/api/tags/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ tag: tagData }),
    }, 'Failed to update tag');
  },

  delete: async (id) => {
    return requestOptionalJson(`/api/tags/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete tag');
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
    return requestJson(`/api/routes/${routeId}/destinations`, {
      method: 'POST',
      body: JSON.stringify({ destination: destData }),
    }, 'Failed to create destination');
  },

  // Update a destination
  update: async (routeId, destId, destData) => {
    return requestJson(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'PUT',
      body: JSON.stringify({ destination: destData }),
    }, 'Failed to update destination');
  },

  // Delete a destination
  delete: async (routeId, destId) => {
    return requestOptionalJson(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'DELETE',
    }, 'Failed to delete destination');
  },
}; 
