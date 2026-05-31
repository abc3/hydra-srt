import { expect, type APIRequestContext, type Page } from '@playwright/test';
import type { InterfaceRecord, SystemInterface } from '../src/types/interfaces';

export type LoginAuth = {
  token: string;
  user: Record<string, unknown>;
};

export type SystemInterfaceRow = Pick<SystemInterface, 'sys_name' | 'ip' | 'id'>;

export type SavedInterfaceRow = InterfaceRecord & { id: string };

export async function loginByApi(page: Page, request: APIRequestContext): Promise<LoginAuth> {
  const response = await request.post('/api/login', {
    data: {
      login: {
        user: 'admin',
        password: 'password123',
      },
    },
  });

  expect(response.ok()).toBeTruthy();
  const payload = (await response.json()) as LoginAuth;

  await page.addInitScript((args: string[]) => {
    const [token, userJson] = args;
    localStorage.setItem('token', token);
    localStorage.setItem('user', userJson);
  }, [payload.token, JSON.stringify(payload.user)]);

  return payload;
}

export async function getFirstIpv4SystemInterface(
  request: APIRequestContext,
  token: string,
): Promise<SystemInterfaceRow> {
  const response = await request.get('/api/interfaces/system', {
    headers: {
      Authorization: `Bearer ${token}`,
    },
    timeout: 5_000,
  });

  expect(response.ok()).toBeTruthy();
  const payload = (await response.json()) as { data: SystemInterfaceRow[] };
  const interfaceRow = payload.data.find(
    (item) => typeof item.ip === 'string' && item.ip.includes('.'),
  );
  expect(interfaceRow).toBeTruthy();
  return interfaceRow as SystemInterfaceRow;
}

export function authHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
}
