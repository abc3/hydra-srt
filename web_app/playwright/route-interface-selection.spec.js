import { test, expect } from '@playwright/test';

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function expectInterfaceSelection(page, aliasName, sysName) {
  const interfaceFormItem = page.locator('.ant-form-item').filter({
    has: page.locator('.ant-form-item-label').filter({ hasText: 'Interface' }),
  }).first();
  const selectedValue = interfaceFormItem.locator('.ant-select-selection-item').first();
  const expectedPattern = new RegExp(`(${escapeRegExp(aliasName)}|${escapeRegExp(sysName)})`);

  await expect(interfaceFormItem).toBeVisible();
  await expect(selectedValue).toBeVisible();
  await expect.poll(async () => (await selectedValue.textContent()) || '').toMatch(expectedPattern);
}

async function loginByApi(page, request) {
  const response = await request.post('/api/login', {
    data: {
      login: {
        user: 'admin',
        password: 'password123',
      },
    },
  });

  expect(response.ok()).toBeTruthy();
  const payload = await response.json();

  await page.addInitScript(([token, user]) => {
    localStorage.setItem('token', token);
    localStorage.setItem('user', JSON.stringify(user));
  }, [payload.token, payload.user]);

  return payload;
}

async function authHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
}

async function getFirstIpv4SystemInterface(request, token) {
  const response = await request.get('/api/interfaces/system', {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  });

  expect(response.ok()).toBeTruthy();
  const payload = await response.json();
  const interfaceRow = payload.data.find((item) => typeof item.ip === 'string' && item.ip.includes('.'));
  expect(interfaceRow).toBeTruthy();
  return interfaceRow;
}

async function listInterfaces(request, headers) {
  const response = await request.get('/api/interfaces', { headers });
  expect(response.ok()).toBeTruthy();
  const payload = await response.json();
  return Array.isArray(payload.data) ? payload.data : [];
}

async function ensureSavedInterface(request, headers, systemInterface, aliasName) {
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
    return (await createResponse.json()).data.id;
  }

  const afterRace = (await listInterfaces(request, headers)).find(
    (item) => item.sys_name === systemInterface.sys_name,
  );

  expect(afterRace).toBeTruthy();

  const updateResponse = await request.put(`/api/interfaces/${afterRace.id}`, {
    headers,
    data: { interface: payload },
  });

  expect(updateResponse.ok()).toBeTruthy();
  return afterRace.id;
}

test('route and destination edit pages keep selected interfaces and endpoint values', async ({ page, request }) => {
  const auth = await loginByApi(page, request);
  const headers = await authHeaders(auth.token);
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
        schema: 'SRT',
        schema_options: {
          mode: 'rendezvous',
          interface_sys_name: systemInterface.sys_name,
          address: '198.51.100.20',
          port: 4209,
          localaddress: '10.0.0.10',
          localport: 4201,
        },
      },
    },
  });

  expect(createRouteResponse.ok()).toBeTruthy();
  const routeId = (await createRouteResponse.json()).data.id;

  const createDestinationResponse = await request.post(`/api/routes/${routeId}/destinations`, {
    headers,
    data: {
      destination: {
        name: 'playwright-destination-interface-persistence',
        enabled: true,
        schema: 'UDP',
        schema_options: {
          interface_sys_name: systemInterface.sys_name,
          host: '239.1.1.1',
          port: 5004,
        },
      },
    },
  });

  expect(createDestinationResponse.ok()).toBeTruthy();
  const destinationId = (await createDestinationResponse.json()).data.id;

  await page.goto(`/#/routes/${routeId}/edit`);
  await expect(page.getByRole('heading', { name: 'Edit Source' })).toBeVisible();
  await expect(page.locator('input[value="198.51.100.20"]').first()).toBeVisible();
  await expect(page.locator('input[value="10.0.0.10"]').first()).toBeVisible();
  await expectInterfaceSelection(page, aliasName, systemInterface.sys_name);
  await expect(page.getByRole('radio', { name: 'Rendezvous' })).toBeChecked();

  await page.goto(`/#/routes/${routeId}/destinations/${destinationId}/edit`);
  await expect(page.getByRole('heading', { name: 'Edit Destination' })).toBeVisible();
  await expect(page.locator('input[value="239.1.1.1"]').first()).toBeVisible();
  await expectInterfaceSelection(page, aliasName, systemInterface.sys_name);
});
