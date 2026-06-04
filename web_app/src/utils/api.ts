/**
 * API service for making authenticated requests to the backend
 */
import { authFetch } from './auth';
import { API_BASE_URL } from './constants';

type JsonPrimitive = string | number | boolean;
type QueryValue = JsonPrimitive | null | undefined;
type QueryParams = Record<string, QueryValue>;
type Payload = Record<string, unknown>;
type ApiError = Error & {
  status?: number;
  payload?: unknown;
  errors?: unknown;
};

const buildQuerySuffix = (params: QueryParams = {}): string => {
  const query = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    if (value === undefined || value === null || value === '') {
      return;
    }
    query.set(key, String(value));
  });
  const asString = query.toString();
  return asString.length > 0 ? `?${asString}` : '';
};

const publicFetch = async (url: string, options: RequestInit = {}) => {
  const fullUrl = url.startsWith('http') ? url : `${API_BASE_URL}${url}`;
  return fetch(fullUrl, options);
};

const parseJsonResponse = async (response: Response): Promise<unknown> => {
  const contentType = response.headers.get('content-type');

  if (!contentType || !contentType.includes('application/json')) {
    return null;
  }

  return response.json();
};

const throwApiErrorIfNeeded = async (response: Response, fallbackMessage: string) => {
  if (response.ok) {
    return;
  }

  const payload = (await parseJsonResponse(response)) as Record<string, unknown> | null;
  const message =
    payload?.error ||
    payload?.message ||
    (payload?.errors ? 'Validation failed' : null) ||
    fallbackMessage;
  const error = new Error(typeof message === 'string' ? message : fallbackMessage) as ApiError;
  error.status = response.status;
  error.payload = payload;
  error.errors = payload?.errors;
  throw error;
};

const requestJson = async <T = unknown>(url: string, options: RequestInit = {}, fallbackMessage = 'Request failed'): Promise<T> => {
  const response = await authFetch(url, options);
  await throwApiErrorIfNeeded(response, fallbackMessage);
  return response.json() as Promise<T>;
};

const requestOptionalJson = async <T = unknown>(url: string, options: RequestInit = {}, fallbackMessage = 'Request failed'): Promise<T | { success: true }> => {
  const response = await authFetch(url, options);
  await throwApiErrorIfNeeded(response, fallbackMessage);
  const payload = await parseJsonResponse(response);
  return (payload as T) ?? { success: true };
};

const requestPublicJson = async <T = unknown>(url: string, options: RequestInit = {}, fallbackMessage = 'Request failed'): Promise<T> => {
  const response = await publicFetch(url, options);
  await throwApiErrorIfNeeded(response, fallbackMessage);
  return response.json() as Promise<T>;
};

export { requestJson, requestOptionalJson };

export const initApi = {
  get: async () => requestPublicJson<Record<string, unknown>>('/api/init', {}, 'Failed to load app init payload'),
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
  kill: async (pid: number | string) => {
    const response = await authFetch(`/api/system/pipelines/${pid}/kill`, {
      method: 'POST',
    });
    return response.json();
  },
};


export type SignalTransport = 'srt' | 'udp' | 'rtp';

export type SignalGenerationTransportConfig = {
  host: string;
  port: number;
};

export type SignalGenerationStatus = {
  transport: SignalTransport;
  running: boolean;
  running_transport: SignalTransport | null;
  host: string;
  port: number;
  transports: Record<SignalTransport, SignalGenerationTransportConfig>;
};

export const signalGenerationApi = {
  status: async (transport: SignalTransport = 'srt'): Promise<SignalGenerationStatus> =>
    requestJson(
      `/api/system/signal-generation?transport=${encodeURIComponent(transport)}`,
      {},
      'Failed to load signal generation status'
    ),

  configure: async ({ transport = 'srt', host, port }: { transport?: SignalTransport; host: string; port: number }): Promise<SignalGenerationStatus> =>
    requestJson(
      '/api/system/signal-generation',
      {
        method: 'PUT',
        body: JSON.stringify({ transport, host, port }),
      },
      'Failed to save signal generation settings'
    ),

  start: async (transport: SignalTransport = 'srt'): Promise<SignalGenerationStatus> =>
    requestJson(
      `/api/system/signal-generation/start?transport=${encodeURIComponent(transport)}`,
      {
        method: 'POST',
      },
      'Failed to start signal generation'
    ),

  stop: async (transport: SignalTransport = 'srt'): Promise<SignalGenerationStatus> =>
    requestJson(
      `/api/system/signal-generation/stop?transport=${encodeURIComponent(transport)}`,
      {
        method: 'POST',
      },
      'Failed to stop signal generation'
    ),
};

// Nodes API
export const nodesApi = {
  // Get all nodes
  getAll: async () => {
    const response = await authFetch('/api/nodes');
    return response.json();
  },
  
  // Get a single node by ID
  getById: async (id: string) => {
    const response = await authFetch(`/api/nodes/${id}`);
    return response.json();
  },

  getAnalytics: async (id: string, params: QueryParams = {}) => {
    const querySuffix = buildQuerySuffix(params);
    const response = await authFetch(`/api/nodes/${encodeURIComponent(id)}/analytics${querySuffix}`);
    return response.json();
  },
};

// Routes API
export const routesApi = {
  // Get all routes
  getAll: async (params: QueryParams = {}) => {
    const querySuffix = buildQuerySuffix(params);
    const response = await authFetch(`/api/routes${querySuffix}`);
    return response.json();
  },

  // Get a single route by ID
  getById: async (id: string) => {
    const response = await authFetch(`/api/routes/${id}`);
    return response.json();
  },

  // Get route analytics time-series
  getAnalytics: async (id: string, params: QueryParams = {}) => {
    const querySuffix = buildQuerySuffix(params);
    const response = await authFetch(`/api/routes/${id}/analytics${querySuffix}`);
    return response.json();
  },

  getEvents: async (id: string, params: QueryParams = {}) => {
    const querySuffix = buildQuerySuffix(params);
    const response = await authFetch(`/api/routes/${id}/events${querySuffix}`);
    return response.json();
  },

  getPipelineLogsDistinct: async (id: string, column: string) => {
    const response = await authFetch(`/api/routes/${id}/pipeline-logs/distinct?column=${encodeURIComponent(column)}`);
    return response.json();
  },

  getPipelineLogs: async (id: string, params: QueryParams = {}) => {
    const querySuffix = buildQuerySuffix(params);
    const response = await authFetch(`/api/routes/${id}/pipeline-logs${querySuffix}`);
    return response.json();
  },

  getStatusesAnalytics: async (params: QueryParams = {}) => {
    const querySuffix = buildQuerySuffix(params);
    const response = await authFetch(`/api/routes/statuses/analytics${querySuffix}`);
    return response.json();
  },

  getStatusesHistory: async (params: QueryParams = {}) => {
    const querySuffix = buildQuerySuffix(params);
    const response = await authFetch(`/api/routes/statuses/history${querySuffix}`);
    return response.json();
  },

  // Create a new route
  create: async (routeData: Payload) => {
    return requestJson('/api/routes', {
      method: 'POST',
      body: JSON.stringify({ route: routeData }),
    }, 'Failed to create route');
  },

  // Update a route
  update: async (id: string, routeData: Payload) => {
    return requestJson(`/api/routes/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ route: routeData }),
    }, 'Failed to update route');
  },

  // Delete a route
  delete: async (id: string) => {
    return requestOptionalJson(`/api/routes/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete route');
  },

  // Start a route
  start: async (id: string) => {
    return requestJson(`/api/routes/${id}/start`, {}, 'Failed to start route');
  },

  // Stop a route
  stop: async (id: string) => {
    return requestJson(`/api/routes/${id}/stop`, {}, 'Failed to stop route');
  },

  // Restart a route
  restart: async (id: string) => {
    return requestJson(`/api/routes/${id}/restart`, {}, 'Failed to restart route');
  },

  switchSource: async (id: string, sourceId: string) => {
    return requestJson(`/api/routes/${id}/switch-source`, {
      method: 'POST',
      body: JSON.stringify({ source_id: sourceId }),
    }, 'Failed to switch source');
  },

  // Test a route source with ffprobe
  testSource: async (routeData: Payload) => {
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
  list: async (routeId: string) => {
    const response = await authFetch(`/api/routes/${routeId}/sources`);
    return response.json();
  },

  get: async (routeId: string, id: string) => {
    const response = await authFetch(`/api/routes/${routeId}/sources/${id}`);
    return response.json();
  },

  create: async (routeId: string, sourceData: Payload) => {
    return requestJson(`/api/routes/${routeId}/sources`, {
      method: 'POST',
      body: JSON.stringify({ source: sourceData }),
    }, 'Failed to create source');
  },

  update: async (routeId: string, id: string, sourceData: Payload) => {
    return requestJson(`/api/routes/${routeId}/sources/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ source: sourceData }),
    }, 'Failed to update source');
  },

  delete: async (routeId: string, id: string) => {
    return requestOptionalJson(`/api/routes/${routeId}/sources/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete source');
  },

  reorder: async (routeId: string, sourceIds: string[]) => {
    return requestJson(`/api/routes/${routeId}/sources/reorder`, {
      method: 'POST',
      body: JSON.stringify({ source_ids: sourceIds }),
    }, 'Failed to reorder sources');
  },

  test: async (routeId: string, id: string) => {
    const response = await authFetch(`/api/routes/${routeId}/sources/${id}/test`, {
      method: 'POST',
    });
    return response.json();
  },

  getThumbnailBlob: async (routeId: string, id: string): Promise<Blob | null> => {
    const response = await authFetch(`/api/routes/${routeId}/sources/${id}/thumbnail`);
    if (response.status === 404) {
      return null;
    }

    await throwApiErrorIfNeeded(response, 'Failed to load source thumbnail');
    return response.blob();
  },
};

// Interfaces API
export const interfacesApi = {
  getAll: async () => {
    const response = await authFetch('/api/interfaces');
    return response.json();
  },

  getById: async (id: string) => {
    const response = await authFetch(`/api/interfaces/${id}`);
    return response.json();
  },

  create: async (interfaceData: Payload) => {
    const response = await authFetch('/api/interfaces', {
      method: 'POST',
      body: JSON.stringify({ interface: interfaceData }),
    });
    return response.json();
  },

  update: async (id: string, interfaceData: Payload) => {
    const response = await authFetch(`/api/interfaces/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ interface: interfaceData }),
    });
    return response.json();
  },

  delete: async (id: string) => {
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
  
  restore: async (file: File) => {
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

export const tagsApi = {
  // Get all unique tag names used across routes (compat for existing selectors)
  getAll: async () => {
    const response = await authFetch('/api/tags');
    const payload = await response.json();
    const list = Array.isArray(payload?.data) ? payload.data : [];
    return { data: list.map((tag: unknown) => (tag as Payload)?.name).filter(Boolean) };
  },

  list: async () => {
    const response = await authFetch('/api/tags');
    return response.json();
  },

  create: async (tagData: Payload) => {
    return requestJson('/api/tags', {
      method: 'POST',
      body: JSON.stringify({ tag: tagData }),
    }, 'Failed to create tag');
  },

  update: async (id: string, tagData: Payload) => {
    return requestJson(`/api/tags/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ tag: tagData }),
    }, 'Failed to update tag');
  },

  delete: async (id: string) => {
    return requestOptionalJson(`/api/tags/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete tag');
  },
};

export const notificationsApi = {
  getTelegram: async () => {
    const response = await authFetch('/api/notifications/telegram');
    return response.json();
  },

  updateTelegram: async (notificationData: Payload) => {
    return requestJson('/api/notifications/telegram', {
      method: 'PUT',
      body: JSON.stringify({ notification: notificationData }),
    }, 'Failed to save Telegram notification settings');
  },

  testTelegram: async (notificationData: Payload | null = null) => {
    const requestOptions: { method: string; body?: string } = {
      method: 'POST',
    };

    if (notificationData) {
      requestOptions.body = JSON.stringify({ notification: notificationData });
    }

    return requestJson('/api/notifications/telegram/test', {
      ...requestOptions,
    }, 'Failed to send Telegram test notification');
  },
};

// Destinations API
export const destinationsApi = {
  // Get all destinations for a route
  getAll: async (routeId: string) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations`);
    return response.json();
  },

  // Get a single destination by ID
  getById: async (routeId: string, destId: string) => {
    const response = await authFetch(`/api/routes/${routeId}/destinations/${destId}`);
    return response.json();
  },

  // Create a new destination
  create: async (routeId: string, destData: Payload) => {
    return requestJson(`/api/routes/${routeId}/destinations`, {
      method: 'POST',
      body: JSON.stringify({ destination: destData }),
    }, 'Failed to create destination');
  },

  // Update a destination
  update: async (routeId: string, destId: string, destData: Payload) => {
    return requestJson(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'PUT',
      body: JSON.stringify({ destination: destData }),
    }, 'Failed to update destination');
  },

  // Delete a destination
  delete: async (routeId: string, destId: string) => {
    return requestOptionalJson(`/api/routes/${routeId}/destinations/${destId}`, {
      method: 'DELETE',
    }, 'Failed to delete destination');
  },
}; 
