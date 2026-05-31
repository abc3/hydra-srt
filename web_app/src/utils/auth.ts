/**
 * Authentication utility functions
 */
import { API_BASE_URL, AUTH_TOKEN_KEY, AUTH_USER_KEY } from './constants';

type AuthUser = Record<string, unknown>;
type AuthHeaders = Record<string, string>;
type AuthFetchOptions = Omit<RequestInit, 'headers'> & {
  headers?: HeadersInit;
};

const getStorage = () => {
  const storage = globalThis?.localStorage;

  if (
    storage &&
    typeof storage.getItem === 'function' &&
    typeof storage.setItem === 'function' &&
    typeof storage.removeItem === 'function'
  ) {
    return storage;
  }

  return null;
};

// Get the authentication token from localStorage
export const getToken = () => {
  const storage = getStorage();
  return storage ? storage.getItem(AUTH_TOKEN_KEY) : null;
};

// Set the authentication token in localStorage
export const setToken = (token: string) => {
  const storage = getStorage();
  if (storage) {
    storage.setItem(AUTH_TOKEN_KEY, token);
  }
};

// Remove the authentication token from localStorage
export const removeToken = () => {
  const storage = getStorage();
  if (storage) {
    storage.removeItem(AUTH_TOKEN_KEY);
  }
};

// Get the user from localStorage
export const getUser = () => {
  const storage = getStorage();
  const userStr = storage ? storage.getItem(AUTH_USER_KEY) : null;
  return userStr ? (JSON.parse(userStr) as AuthUser) : null;
};

// Set the user in localStorage
export const setUser = (user: AuthUser) => {
  const storage = getStorage();
  if (storage) {
    storage.setItem(AUTH_USER_KEY, JSON.stringify(user));
  }
};

// Remove the user from localStorage
export const removeUser = () => {
  const storage = getStorage();
  if (storage) {
    storage.removeItem(AUTH_USER_KEY);
  }
};

// Check if the user is authenticated
export const isAuthenticated = () => {
  return !!getToken();
};

// Add the authentication token to API requests
export const authHeader = () => {
  const token = getToken();
  return token ? ({ Authorization: `Bearer ${token}` } as AuthHeaders) : ({} as AuthHeaders);
};

const headersToRecord = (headers: HeadersInit | undefined): AuthHeaders => {
  if (!headers) {
    return {};
  }

  if (headers instanceof Headers) {
    return Object.fromEntries(headers.entries());
  }

  if (Array.isArray(headers)) {
    return Object.fromEntries(headers);
  }

  return { ...headers };
};

// Create an authenticated fetch function
export const authFetch = async (url: string, options: AuthFetchOptions = {}) => {
  const optionHeaders = headersToRecord(options.headers);
  const headers: AuthHeaders = {
    ...authHeader(),
    ...optionHeaders,
  };

  // Only set Content-Type to application/json if:
  // 1. The body is not FormData
  // 2. Content-Type is not already set in options.headers
  if (!(options.body instanceof FormData) && !optionHeaders['Content-Type']) {
    headers['Content-Type'] = 'application/json';
  }

  const config = {
    ...options,
    headers,
  };

  try {
    // Prepend API_BASE_URL if the URL doesn't already include it
    const fullUrl = url.startsWith('http') ? url : `${API_BASE_URL}${url}`;
    const response = await fetch(fullUrl, config);
    
    // If 401 Unauthorized or 403 Forbidden, clear token and redirect to login
    if (response.status === 401 || response.status === 403) {
      removeToken();
      removeUser();
      window.location.href = '/#/login';
      return Promise.reject('Authentication error');
    }
    
    return response;
  } catch (error) {
    return Promise.reject(error);
  }
};

// Login function
export const login = async (username: string, password: string) => {
  try {
    const response = await fetch(`${API_BASE_URL}/api/login`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ 
        login: {
          user: username, 
          password: password
        }
      }),
    });

    if (!response.ok) {
      throw new Error('Login failed');
    }

    const data = (await response.json()) as { token: string; user: AuthUser };
    setToken(data.token);
    setUser(data.user);
    return data;
  } catch (error) {
    console.error('Login error:', error);
    throw error;
  }
};

// Logout function
export const logout = () => {
  removeToken();
  removeUser();
  window.location.href = '/#/login';
}; 
