import { defineConfig } from '@playwright/test';

const host = process.env.E2E_HOST || '127.0.0.1';
const port = process.env.E2E_PORT || process.env.PORT || '4000';
const isCI = process.env.CI === 'true' || process.env.CI === '1';

export default defineConfig({
  testDir: './playwright',
  globalTimeout: 12 * 60_000,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  // Forced to 1 everywhere (not just CI): the specs share one backend server,
  // one SQLite database, and the host machine's real network interface list.
  // Running them across parallel workers races on shared rows (e.g.
  // interfaces.spec.ts and route-interface-selection.spec.ts both mutate the
  // saved-interface row for the same system interface), so this suite is not
  // parallel-safe regardless of environment.
  workers: 1,
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
