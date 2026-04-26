import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { configDefaults } from 'vitest/config'

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
    proxy,
  },
  test: {
    environment: 'jsdom',
    setupFiles: './src/test/setup.js',
    globals: true,
    exclude: [...configDefaults.exclude, 'playwright/**'],
  },
})
