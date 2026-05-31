import { test, expect, type APIRequestContext, type Page } from '@playwright/test';
import {
  authHeaders,
  getFirstIpv4SystemInterface,
  loginByApi,
  type SavedInterfaceRow,
  type SystemInterfaceRow,
} from './helpers';

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function expectInterfaceSelection(page: Page, aliasName: string, sysName: string) {
  const interfaceFormItem = page.locator('.ant-form-item').filter({
    has: page.locator('.ant-form-item-label').filter({ hasText: 'Interface' }),
  }).first();
  const selectedValue = interfaceFormItem.locator('.ant-select-selection-item').first();
  const expectedPattern = new RegExp(`(${escapeRegExp(aliasName)}|${escapeRegExp(sysName)})`);

  await expect(interfaceFormItem).toBeVisible();
  await expect(selectedValue).toBeVisible();
  await expect.poll(async () => (await selectedValue.textContent()) || '').toMatch(expectedPattern);
}

async function listInterfaces(
  request: APIRequestContext,
  headers: Record<string, string>,
): Promise<SavedInterfaceRow[]> {
  const response = await request.get('/api/interfaces', {
    headers,
    timeout: 5_000,
  });
  expect(response.ok()).toBeTruthy();
  const payload = (await response.json()) as { data?: SavedInterfaceRow[] };
  return Array.isArray(payload.data) ? payload.data : [];
}

async function ensureSavedInterface(
  request: APIRequestContext,
  headers: Record<string, string>,
  systemInterface: SystemInterfaceRow,
  aliasName: string,
): Promise<string> {
  const payload = {
    name: aliasName,
    sys_name: systemInterface.sys_name,
    ip: systemInterface.ip,
    enabled: true,
  };

  const existing = (await listInterfaces(request, headers)).find(
    (item) => item.sys_name === systemInterface.sys_name,
  );

  if (existing) {
    const updateResponse = await request.put(`/api/interfaces/${existing.id}`, {
      headers,
      data: { interface: payload },
    });

    expect(updateResponse.ok()).toBeTruthy();
    return existing.id;
  }

  const createResponse = await request.post('/api/interfaces', {
    headers,
    data: { interface: payload },
  });

  if (createResponse.ok()) {
    const created = (await createResponse.json()) as { data: { id: string } };
    return created.data.id;
  }

  const afterRace = (await listInterfaces(request, headers)).find(
    (item) => item.sys_name === systemInterface.sys_name,
  );

  expect(afterRace).toBeTruthy();

  const updateResponse = await request.put(`/api/interfaces/${afterRace!.id}`, {
    headers,
    data: { interface: payload },
  });

  expect(updateResponse.ok()).toBeTruthy();
  return afterRace!.id;
}

test('route and destination edit pages keep selected interfaces and endpoint values', async ({ page, request }) => {
  const auth = await loginByApi(page, request);
  const headers = authHeaders(auth.token);
  const systemInterface = await getFirstIpv4SystemInterface(request, auth.token);
  const aliasName = `PW Persist ${systemInterface.sys_name}`;

  await ensureSavedInterface(request, headers, systemInterface, aliasName);

  const createRouteResponse = await request.post('/api/routes', {
    headers,
    data: {
      route: {
        name: 'playwright-route-interface-persistence',
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
        schema: 'SRT',
        position: 0,
        mode: 'rendezvous',
        interface_sys_name: systemInterface.sys_name,
        address: '198.51.100.20',
        port: 9000,
        localaddress: '10.0.0.10',
        localport: 9000,
      },
    },
  });

  expect(createSourceResponse.ok()).toBeTruthy();

  const createDestinationResponse = await request.post(`/api/routes/${routeId}/destinations`, {
    headers,
    data: {
      destination: {
        name: 'playwright-destination-interface-persistence',
        enabled: true,
        schema: 'UDP',
        interface_sys_name: systemInterface.sys_name,
        host: '239.1.1.1',
        port: 5000,
      },
    },
  });

  expect(createDestinationResponse.ok()).toBeTruthy();
  const destinationPayload = (await createDestinationResponse.json()) as { data: { id: string } };
  const destinationId = destinationPayload.data.id;

  await page.goto(`/#/routes/${routeId}/edit`);
  await expect(page.getByRole('heading', { name: 'Edit Route' })).toBeVisible();
  await expect(page.locator('input[value="198.51.100.20"]').first()).toBeVisible();
  await expect(page.locator('input[value="10.0.0.10"]').first()).toBeVisible();
  await expectInterfaceSelection(page, aliasName, systemInterface.sys_name);
  await expect(page.getByRole('radio', { name: 'Rendezvous' })).toBeChecked();

  await page.goto(`/#/routes/${routeId}/destinations/${destinationId}/edit`);
  await expect(page.getByRole('heading', { name: 'Edit Destination' })).toBeVisible();
  await expect(page.locator('input[value="239.1.1.1"]').first()).toBeVisible();
  await expectInterfaceSelection(page, aliasName, systemInterface.sys_name);
});
