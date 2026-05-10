import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { configDefaults } from 'vitest/config'

const toBoolean = (value, defaultValue) => {
  if (value === undefined || value === null || value === '') {
    return defaultValue
  }

  const normalized = String(value).trim().toLowerCase()
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false
  return defaultValue
}

const devHost = process.env.VITE_DEV_HOST || 'localhost'
const devPort = Number(process.env.VITE_DEV_PORT || 5173)
const devStrictPort = toBoolean(process.env.VITE_DEV_STRICT_PORT, true)

const proxy = {
  // Web UI often uses page origin (e.g. http://LAN:5173) with API_BASE_URL matching
  // that origin so /api is proxied to Phoenix. Phoenix Channels must use the same
  // pattern: proxy /socket with WS upgrades, otherwise the browser hangs on
  // ws://...:5173/socket/websocket waiting for a Phoenix handshake that never comes.
  '^/(api|backup|socket)': {
    target: 'http://127.0.0.1:4000',
    changeOrigin: true,
    ws: true,
  },
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    host: devHost,
    port: Number.isFinite(devPort) ? devPort : 5173,
    strictPort: devStrictPort,
    proxy,
  },
  test: {
    environment: 'jsdom',
    setupFiles: './src/test/setup.js',
    globals: true,
    exclude: [...configDefaults.exclude, 'playwright/**'],
  },
})
