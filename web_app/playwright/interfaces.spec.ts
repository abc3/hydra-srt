import { test, expect, type APIRequestContext, type Page } from '@playwright/test';
import { getFirstIpv4SystemInterface, loginByApi } from './helpers';

async function openFirstSourceInterfaceSelect(page: Page) {
  const sourceCard = page.locator('.ant-card').filter({ hasText: 'Primary Source' });
  const interfaceField = sourceCard.locator('.ant-form-item').filter({ hasText: 'Interface' }).first();
  await interfaceField.locator('.ant-select').click();
}

async function waitForInterfaceOptionVisibility(
  page: Page,
  labelPart: string,
  expectedVisible: boolean,
) {
  await expect
    .poll(async () => {
      return page
        .locator('[role="option"]')
        .evaluateAll((nodes, needle) => nodes.some((node) => {
          const label = node.getAttribute('aria-label') || '';
          if (!label.includes(needle)) {
            return false;
          }

          const hiddenByAria = node.getAttribute('aria-hidden') === 'true';
          const hiddenByStyle = node instanceof HTMLElement && node.offsetParent === null;
          return !hiddenByAria && !hiddenByStyle;
        }), labelPart);
    }, {
      timeout: 20_000,
    })
    .toBe(expectedVisible);
}

async function waitForInterfaceAliasState(
  request: APIRequestContext,
  token: string,
  sysName: string,
  expected: { enabled: boolean; name: string },
) {
  await expect
    .poll(async () => {
      const response = await request.get('/api/interfaces', {
        headers: {
          Authorization: `Bearer ${token}`,
        },
        timeout: 5_000,
      });

      if (!response.ok()) {
        return false;
      }

      const payload = (await response.json()) as {
        data?: Array<{ sys_name?: string; enabled?: boolean; name?: string }>;
      };
      const row = (payload.data || []).find((item) => item?.sys_name === sysName);

      if (!row) {
        return false;
      }

      return row.enabled === expected.enabled && row.name === expected.name;
    }, {
      timeout: 20_000,
    })
    .toBe(true);
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
  await waitForInterfaceAliasState(request, auth.token, systemInterface.sys_name, {
    enabled: true,
    name: aliasName,
  });

  const switchLocator = row.getByRole('switch');
  await expect(switchLocator).toHaveAttribute('aria-checked', 'true');
  await expect(switchLocator).toBeEnabled();
  await switchLocator.click();
  await waitForInterfaceAliasState(request, auth.token, systemInterface.sys_name, {
    enabled: false,
    name: aliasName,
  });

  await page.goto('/#/routes/new/edit');
  await expect(page.getByRole('heading', { name: 'Add Route' })).toBeVisible();
  await openFirstSourceInterfaceSelect(page);
  await waitForInterfaceOptionVisibility(page, aliasName, false);
  await page.keyboard.press('Escape');

  await page.goto('/#/interfaces');
  const sameRow = page.locator('tr').filter({ hasText: systemInterface.sys_name }).first();
  const sameSwitch = sameRow.getByRole('switch');
  await expect(sameSwitch).toBeEnabled();
  await sameSwitch.click();
  await waitForInterfaceAliasState(request, auth.token, systemInterface.sys_name, {
    enabled: true,
    name: aliasName,
  });

  await page.goto('/#/routes/new/edit');
  await openFirstSourceInterfaceSelect(page);
  await waitForInterfaceOptionVisibility(page, aliasName, true);
});
