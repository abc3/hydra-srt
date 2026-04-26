import { test, expect } from '@playwright/test';

test('GET /health/ returns 200', async ({ request }) => {
  const response = await request.get('/health/');
  expect(response.status()).toBe(200);
});
