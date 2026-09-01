import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getToken, getUser, login } from '../auth';

const installLocalStorage = () => {
  const values = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => values.delete(key),
    setItem: (key, value) => values.set(key, value),
  };

  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: storage,
    writable: true,
  });
};

describe('login', () => {
  beforeEach(() => {
    installLocalStorage();
    localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    localStorage.clear();
  });

  it('preserves the status and nested payload for invalid credentials', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({
          error: {
            code: 'INVALID_CREDENTIALS',
            message: 'Invalid username or password',
          },
        }), {
          status: 401,
          headers: { 'content-type': 'application/json' },
        }),
      ),
    );

    await expect(login('admin', 'wrong-password')).rejects.toMatchObject({
      status: 401,
      payload: {
        error: {
          code: 'INVALID_CREDENTIALS',
        },
      },
    });
  });

  it('propagates transport failures without adding an HTTP status', async () => {
    const fetchError = new Error('network down');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(fetchError));

    await expect(login('admin', 'password')).rejects.toBe(fetchError);
    await expect(login('admin', 'password')).rejects.not.toHaveProperty('status');
  });

  it('stores the token and user after a successful login', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ token: 'token-123', user: 'admin' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
      ),
    );

    await login('admin', 'password');

    expect(getToken()).toBe('token-123');
    expect(getUser()).toBe('admin');
  });
});
