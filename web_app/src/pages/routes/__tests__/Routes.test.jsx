import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Routes from '../Routes';
import { routesApi } from '../../../utils/api';

vi.mock('../../../utils/api', () => ({
  routesApi: {
    getAll: vi.fn(),
    start: vi.fn(async () => ({ data: { status: 'started' } })),
    stop: vi.fn(async () => ({ data: { status: 'stopped' } })),
    delete: vi.fn(async () => ({ success: true })),
  },
}));

vi.mock('../../../utils/realtime', () => ({
  subscribeToStats: vi.fn(() => vi.fn()),
}));

const routeFixture = (attrs) => ({
  id: attrs.id,
  name: attrs.name,
  enabled: true,
  status: attrs.status,
  schema_status: attrs.schema_status,
  schema: 'SRT',
  schema_options: { localaddress: '127.0.0.1', localport: 4201 },
  started_at: null,
  destinations: [],
  ...attrs,
});

describe('Routes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    routesApi.getAll.mockResolvedValue({
      data: [
        routeFixture({
          id: 'starting-route',
          name: 'Starting route',
          status: 'started',
          schema_status: 'starting',
        }),
        routeFixture({
          id: 'stopped-route',
          name: 'Stopped route',
          status: 'stopped',
          schema_status: 'stopped',
        }),
      ],
    });
  });

  it('shows enabled Stop action for non-stopped routes', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findByText('Starting route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for starting route/i }));

    const stopAction = await screen.findByRole('menuitem', { name: /stop/i });
    expect(stopAction).not.toHaveAttribute('aria-disabled', 'true');
  });

  it('shows Start action for stopped routes', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findByText('Stopped route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for stopped route/i }));

    expect(await screen.findByRole('menuitem', { name: /start/i })).toBeInTheDocument();
  });
});
