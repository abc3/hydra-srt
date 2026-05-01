import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Routes from '../Routes';
import { routesApi } from '../../../utils/api';
import {
  subscribeToItemSource,
  subscribeToItemStatus,
  __clearRealtimeMockState,
  __emitItemSource,
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
  const itemSourceListeners = new Map();

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

  const subscribeToItemSource = vi.fn((itemId, listener) => {
    const listeners = itemSourceListeners.get(itemId) || [];
    listeners.push(listener);
    itemSourceListeners.set(itemId, listeners);

    return vi.fn(() => {
      const current = itemSourceListeners.get(itemId) || [];
      itemSourceListeners.set(
        itemId,
        current.filter((saved) => saved !== listener),
      );
    });
  });

  return {
    subscribeToItemSource,
    subscribeToItemStatus,
    subscribeToStats,
    __emitItemStatus: (itemId, status) => {
      const listeners = itemListeners.get(itemId) || [];
      listeners.forEach((listener) => listener({ item_id: itemId, status }));
    },
    __emitStats: (payload) => {
      statsListeners.forEach((listener) => listener(payload));
    },
    __emitItemSource: (itemId, activeSourceId, reason = 'manual') => {
      const listeners = itemSourceListeners.get(itemId) || [];
      listeners.forEach((listener) => listener({
        item_id: itemId,
        active_source_id: activeSourceId,
        last_switch_reason: reason,
      }));
    },
    __clearRealtimeMockState: () => {
      itemListeners.clear();
      statsListeners.clear();
      itemSourceListeners.clear();
      subscribeToItemSource.mockClear();
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
  sources: [
    { id: `${attrs.id}-primary`, position: 0, enabled: true, name: 'primary' },
    { id: `${attrs.id}-backup`, position: 1, enabled: true, name: 'backup-1' },
  ],
  active_source_id: `${attrs.id}-primary`,
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
          last_switch_at: new Date(Date.now() - 30_000).toISOString(),
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

    await screen.findAllByText('Starting route');

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

    await screen.findAllByText('Stopped route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for stopped route/i }));

    expect(await screen.findByRole('menuitem', { name: /start/i })).toBeInTheDocument();
  });

  it('subscribes to route status events and updates the list status', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findAllByText('Starting route');

    expect(subscribeToItemStatus).toHaveBeenCalledWith('starting-route', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('stopped-route', expect.any(Function));
    expect(subscribeToItemSource).toHaveBeenCalledWith('starting-route', expect.any(Function));
    expect(subscribeToItemSource).toHaveBeenCalledWith('stopped-route', expect.any(Function));

    await act(async () => {
      __emitItemStatus('starting-route', 'processing');
    });

    expect(await screen.findByText('running')).toBeInTheDocument();
  });

  it('updates active source badge on item_source event', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findAllByText('Starting route');
    expect(screen.getAllByText('PRIMARY').length).toBeGreaterThan(0);

    await act(async () => {
      __emitItemSource('starting-route', 'starting-route-backup', 'manual');
    });

    expect(await screen.findByText('BACKUP: backup-1')).toBeInTheDocument();
  });

  it('shows switch counter and unstable marker for recent switches', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findAllByText('Starting route');
    expect(screen.getByText('Switches last 1h')).toBeInTheDocument();
    expect(screen.getByText('unstable')).toBeInTheDocument();
  });

  it('shows route in and out stats while status is not stopped', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findAllByText('Starting route');

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
    });

    expect(await screen.findByText('800 bps / 1.60 Kbps')).toBeInTheDocument();
  });

  it('disables stats action for stopped routes', async () => {
    render(
      <MemoryRouter>
        <Routes />
      </MemoryRouter>,
    );

    await screen.findByText('Stopped route');

    expect(screen.getByRole('button', { name: /route stats for stopped route/i })).toBeDisabled();
    expect(screen.getByRole('button', { name: /route stats for starting route/i })).not.toBeDisabled();
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
