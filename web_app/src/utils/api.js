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
    return response.json();
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
    return response.json();
  },
}; 