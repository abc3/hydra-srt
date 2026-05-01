import { test, expect } from '@playwright/test';

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

async function openFirstSourceInterfaceSelect(page) {
  const sourceCard = page.locator('.ant-card').filter({ hasText: 'Primary Source' });
  const interfaceField = sourceCard.locator('.ant-form-item').filter({ hasText: 'Interface' }).first();
  await interfaceField.locator('.ant-select').click();
}

test('interface visibility toggle controls route selector options', async ({ page, request }) => {
  const auth = await loginByApi(page, request);
  const systemInterface = await getFirstIpv4SystemInterface(request, auth.token);
  const aliasName = `PW Alias ${systemInterface.sys_name}`;

  await page.goto('/#/interfaces');
  await expect(page.getByRole('heading', { name: 'Interfaces' })).toBeVisible();

  const row = page.locator('tr').filter({ hasText: systemInterface.sys_name }).first();
  await expect(row).toBeVisible();

  await row.locator('td').first().click();
  const aliasInput = row.locator('input').first();
  await aliasInput.fill(aliasName);
  await aliasInput.press('Enter');
  await expect(page.getByText(aliasName)).toBeVisible();

  const switchLocator = row.getByRole('switch');
  await expect(switchLocator).toHaveAttribute('aria-checked', 'true');
  await switchLocator.click();
  await expect(switchLocator).toHaveAttribute('aria-checked', 'false');

  await page.goto('/#/routes/new/edit');
  await expect(page.getByRole('heading', { name: 'Add Route' })).toBeVisible();
  await openFirstSourceInterfaceSelect(page);
  await expect(page.getByText(aliasName)).toHaveCount(0);
  await page.keyboard.press('Escape');

  await page.goto('/#/interfaces');
  const sameRow = page.locator('tr').filter({ hasText: systemInterface.sys_name }).first();
  const sameSwitch = sameRow.getByRole('switch');
  await sameSwitch.click();
  await expect(sameSwitch).toHaveAttribute('aria-checked', 'true');

  await page.goto('/#/routes/new/edit');
  await openFirstSourceInterfaceSelect(page);
  await expect(page.getByText(aliasName)).toBeVisible();
});
