import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Routes from '../Routes';
import { routesApi } from '../../../utils/api';
import {
  subscribeToItemStatus,
  __clearRealtimeMockState,
  __emitItemStatus,
  __emitStats,
} from '../../../utils/realtime';

vi.mock('../../../utils/api', () => ({
  routesApi: {
    getAll: vi.fn(),
    start: vi.fn(async () => ({ data: { status: 'starting' } })),
    stop: vi.fn(async () => ({ data: { status: 'stopped' } })),
    delete: vi.fn(async () => ({ success: true })),
  },
}));

vi.mock('../../../utils/realtime', () => {
  const itemListeners = new Map();
  const statsListeners = new Set();

  const subscribeToItemStatus = vi.fn((itemId, listener) => {
    const listeners = itemListeners.get(itemId) || [];
    listeners.push(listener);
    itemListeners.set(itemId, listeners);

    return vi.fn(() => {
      const current = itemListeners.get(itemId) || [];
      itemListeners.set(
        itemId,
        current.filter((saved) => saved !== listener),
      );
    });
  });

  const subscribeToStats = vi.fn((listener) => {
    statsListeners.add(listener);
    return vi.fn(() => {
      statsListeners.delete(listener);
    });
  });

  return {
    subscribeToItemStatus,
    subscribeToStats,
    __emitItemStatus: (itemId, status) => {
      const listeners = itemListeners.get(itemId) || [];
      listeners.forEach((listener) => listener({ item_id: itemId, status }));
    },
    __emitStats: (payload) => {
      statsListeners.forEach((listener) => listener(payload));
    },
    __clearRealtimeMockState: () => {
      itemListeners.clear();
      statsListeners.clear();
      subscribeToItemStatus.mockClear();
      subscribeToStats.mockClear();
    },
  };
});

const routeFixture = (attrs) => ({
  id: attrs.id,
  name: attrs.name,
  enabled: true,
  status: attrs.status,
  schema_status: attrs.schema_status,
  schema: 'SRT',
  schema_options: { localaddress: '127.0.0.1', localport: 4201 },
  started_at: attrs.started_at ?? null,
  destinations: [],
  ...attrs,
});

describe('Routes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    __clearRealtimeMockState();
    routesApi.getAll.mockResolvedValue({
      data: [
        routeFixture({
          id: 'starting-route',
          name: 'Starting route',
          status: 'starting',
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

  it('subscribes to route status events and updates the list status', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findByText('Starting route');

    expect(subscribeToItemStatus).toHaveBeenCalledWith('starting-route', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('stopped-route', expect.any(Function));

    await act(async () => {
      __emitItemStatus('starting-route', 'processing');
    });

    expect(await screen.findByText('running')).toBeInTheDocument();
  });

  it('shows route in and out stats after the route reports processing', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findByText('Starting route');

    await act(async () => {
      __emitStats({
        route_id: 'starting-route',
        metric: 'bytes_per_sec',
        direction: 'in',
        value: 100,
      });
      __emitStats({
        route_id: 'starting-route',
        destination_id: 'dest-1',
        metric: 'bytes_per_sec',
        direction: 'out',
        value: 200,
      });
      __emitItemStatus('starting-route', 'processing');
    });

    expect(await screen.findByText('800 bps / 1.60 Kbps')).toBeInTheDocument();
  });

  it('shows uptime for routes that are starting or running', async () => {
    const startedAt = new Date(Date.now() - 60_000).toISOString();

    routesApi.getAll.mockResolvedValue({
      data: [
        routeFixture({
          id: 'running-route',
          name: 'Running route',
          status: 'starting',
          schema_status: 'processing',
          started_at: startedAt,
        }),
      ],
    });

    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    expect(await screen.findByText('1m')).toBeInTheDocument();
  });
});
