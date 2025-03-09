/**
 * Authentication utility functions
 */
import { API_BASE_URL, AUTH_TOKEN_KEY, AUTH_USER_KEY } from './constants';

// Get the authentication token from localStorage
export const getToken = () => {
  return localStorage.getItem(AUTH_TOKEN_KEY);
};

// Set the authentication token in localStorage
export const setToken = (token) => {
  localStorage.setItem(AUTH_TOKEN_KEY, token);
};

// Remove the authentication token from localStorage
export const removeToken = () => {
  localStorage.removeItem(AUTH_TOKEN_KEY);
};

// Get the user from localStorage
export const getUser = () => {
  const userStr = localStorage.getItem(AUTH_USER_KEY);
  return userStr ? JSON.parse(userStr) : null;
};

// Set the user in localStorage
export const setUser = (user) => {
  localStorage.setItem(AUTH_USER_KEY, JSON.stringify(user));
};

// Remove the user from localStorage
export const removeUser = () => {
  localStorage.removeItem(AUTH_USER_KEY);
};

// Check if the user is authenticated
export const isAuthenticated = () => {
  return !!getToken();
};

// Add the authentication token to API requests
export const authHeader = () => {
  const token = getToken();
  return token ? { 'Authorization': `Bearer ${token}` } : {};
};

// Create an authenticated fetch function
export const authFetch = async (url, options = {}) => {
  const headers = {
    'Content-Type': 'application/json',
    ...authHeader(),
    ...options.headers,
  };

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
export const login = async (username, password) => {
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

    const data = await response.json();
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