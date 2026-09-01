import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getToken } from '../../utils/auth';
import Login from '../Login';

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

const fillAndSubmitLogin = () => {
  fireEvent.change(screen.getByPlaceholderText('Username'), { target: { value: 'admin' } });
  fireEvent.change(screen.getByPlaceholderText('Password'), { target: { value: 'password' } });
  fireEvent.click(screen.getByRole('button', { name: 'Sign In' }));
};

const renderLogin = () => {
  render(
    <MemoryRouter initialEntries={['/login']}>
      <Login />
    </MemoryRouter>,
  );
};

describe('Login', () => {
  beforeEach(() => {
    installLocalStorage();
    localStorage.clear();
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    localStorage.clear();
  });

  it('shows the invalid credentials error and clears the password after a 401', async () => {
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
    renderLogin();

    fillAndSubmitLogin();

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('Invalid username or password');
    expect(screen.getByPlaceholderText('Password')).toHaveValue('');
  });

  it('shows the server error for a 500 response', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ error: 'internal failure' }), {
          status: 500,
          headers: { 'content-type': 'application/json' },
        }),
      ),
    );
    renderLogin();

    fillAndSubmitLogin();

    expect(await screen.findByRole('alert')).toHaveTextContent('Server error. Please try again.');
  });

  it('shows the server unreachable error for a rejected fetch', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network down')));
    renderLogin();

    fillAndSubmitLogin();

    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Cannot reach the server. Check your connection and try again.',
    );
  });

  it('stores the token and does not render an alert after a successful login', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ token: 'token-123', user: 'admin' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
      ),
    );
    renderLogin();

    fillAndSubmitLogin();

    await waitFor(() => expect(getToken()).toBe('token-123'));
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});
