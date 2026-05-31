import { defineConfig } from '@playwright/test';

const host = process.env.E2E_HOST || '127.0.0.1';
const port = process.env.E2E_PORT || process.env.PORT || '4000';
const isCI = process.env.CI === 'true' || process.env.CI === '1';

export default defineConfig({
  testDir: './playwright',
  globalTimeout: 12 * 60_000,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  workers: isCI ? 1 : undefined,
  maxFailures: isCI ? 1 : undefined,
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
