/**
 * Application constants
 */

// API base URL
// Prefer a Vite env override, but guard against a common foot-gun:
// - If the UI is opened via a non-loopback IP/host (e.g. http://192.168.x.x:4000)
// - And VITE_API_BASE_URL was built as http://127.0.0.1:4000 (or localhost)
// ...then remote clients would incorrectly call their own loopback.
const envApiBaseUrl =
  typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_BASE_URL
    ? String(import.meta.env.VITE_API_BASE_URL)
    : null;

const pageOrigin =
  typeof window !== 'undefined' && window.location && window.location.origin
    ? window.location.origin
    : null;

const pageHost =
  typeof window !== 'undefined' && window.location && window.location.hostname
    ? window.location.hostname
    : null;

const isLoopbackHost = (host) => host === 'localhost' || host === '127.0.0.1' || host === '::1';

const isEnvLoopbackUrl =
  !!envApiBaseUrl && /^https?:\/\/(localhost|127\.0\.0\.1|\[?::1\]?)(:\d+)?$/i.test(envApiBaseUrl);

const shouldIgnoreEnvApiBaseUrl =
  !!envApiBaseUrl && isEnvLoopbackUrl && !!pageHost && !isLoopbackHost(pageHost);

export const API_BASE_URL =
  (envApiBaseUrl && !shouldIgnoreEnvApiBaseUrl ? envApiBaseUrl : null) ||
  pageOrigin ||
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