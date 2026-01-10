/**
 * Application constants
 */

// API base URL
// Prefer Vite env override, then same-origin (Phoenix serving the UI), then dev default.
export const API_BASE_URL =
  (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_BASE_URL) ||
  (typeof window !== 'undefined' && window.location && window.location.origin) ||
  'http://127.0.0.1:4000';

// Authentication
export const AUTH_TOKEN_KEY = 'token';
export const AUTH_USER_KEY = 'user';

// Routes
export const ROUTES = {
  LOGIN: '/login',
  DASHBOARD: '/',
  ROUTES: '/routes',
  SETTINGS: '/settings',
  SYSTEM_PIPELINES: '/system/pipelines',
  SYSTEM_NODES: '/system/nodes',
}; 