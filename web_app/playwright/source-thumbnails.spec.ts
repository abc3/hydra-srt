import { test, expect } from '@playwright/test';
import { authHeaders, loginByApi } from './helpers';

test('source thumbnail settings are editable and visible on route detail', async ({ page, request }) => {
  const auth = await loginByApi(page, request);
  const headers = authHeaders(auth.token);

  const routeName = `playwright-source-thumbnails-${Date.now()}`;
  const sourcePort = 19_500 + Math.floor(Math.random() * 1_000);
  const createRouteResponse = await request.post('/api/routes', {
    headers,
    data: {
      route: {
        name: routeName,
        enabled: true,
        node: 'self',
      },
    },
  });

  expect(createRouteResponse.ok()).toBeTruthy();
  const routePayload = (await createRouteResponse.json()) as { data: { id: string } };
  const routeId = routePayload.data.id;

  const createSourceResponse = await request.post(`/api/routes/${routeId}/sources`, {
    headers,
    data: {
      source: {
        enabled: true,
        name: 'Primary',
        schema: 'UDP',
        position: 0,
        address: '127.0.0.1',
        port: sourcePort,
        thumbnail_enabled: true,
        thumbnail_interval_ms: 5000,
        thumbnail_capture_policy: 'always',
      },
    },
  });

  expect(createSourceResponse.ok()).toBeTruthy();

  await page.goto(`/#/routes/${routeId}/edit`);
  await expect(page.getByRole('heading', { name: 'Edit Route' })).toBeVisible();
  await expect(page.getByText('Thumbnail Interval (ms)')).toBeVisible();
  await expect(page.getByText('Thumbnail Capture')).toBeVisible();
  await expect(page.locator('input[value="5000"]').first()).toBeVisible();

  await page.goto(`/#/routes/${routeId}`);
  await expect(page.getByText('Endpoints')).toBeVisible();
  await expect(page.getByText('Thumbnail')).toBeVisible();
  await expect(page.getByText(/No thumbnail|Loading/)).toBeVisible();
});
