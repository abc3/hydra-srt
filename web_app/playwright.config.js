import { defineConfig } from '@playwright/test';

const host = process.env.E2E_HOST || '127.0.0.1';
const port = process.env.E2E_PORT || process.env.PORT || '4000';

export default defineConfig({
  testDir: './playwright',
  timeout: 120_000,
  expect: { timeout: 20_000 },
  use: {
    baseURL: `http://${host}:${port}`,
    headless: true,
  },
  webServer: {
    command: 'npm run e2e:server',
    url: `http://${host}:${port}/health/`,
    reuseExistingServer: true,
    timeout: 180_000,
  },
});

