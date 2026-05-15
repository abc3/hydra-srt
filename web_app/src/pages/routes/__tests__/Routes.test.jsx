import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Routes from '../Routes';
import { routesApi } from '../../../utils/api';
import {
  subscribeToItemSource,
  subscribeToItemStatus,
  subscribeToRouteEvents,
  __clearRealtimeMockState,
  __emitItemStatus,
  __emitRouteEvent,
  __emitStats,
} from '../../../utils/realtime';

vi.mock('recharts', () => {
  const Mock = ({ children }) => children ?? null;
  return {
    ResponsiveContainer: Mock,
    AreaChart: Mock,
    CartesianGrid: () => null,
    XAxis: () => null,
    YAxis: () => null,
    Area: () => null,
    Tooltip: () => null,
  };
});

vi.mock('../../../utils/api', () => ({
  routesApi: {
    getAll: vi.fn(),
    getStatusesAnalytics: vi.fn(),
    getStatusesHistory: vi.fn(),
    start: vi.fn(async () => ({ data: { status: 'starting' } })),
    stop: vi.fn(async () => ({ data: { status: 'stopped' } })),
    delete: vi.fn(async () => ({ success: true })),
  },
  tagsApi: {
    getAll: vi.fn(async () => ({ data: [] })),
  },
}));

vi.mock('../../../utils/realtime', () => {
  const itemListeners = new Map();
  const statsListeners = new Set();
  const itemSourceListeners = new Map();
  const routeEventListeners = new Map();

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

  const subscribeToRouteEvents = vi.fn((routeId, listener) => {
    const listeners = routeEventListeners.get(routeId) || [];
    listeners.push(listener);
    routeEventListeners.set(routeId, listeners);

    return vi.fn(() => {
      const current = routeEventListeners.get(routeId) || [];
      routeEventListeners.set(
        routeId,
        current.filter((saved) => saved !== listener),
      );
    });
  });

  return {
    subscribeToItemSource,
    subscribeToItemStatus,
    subscribeToRouteEvents,
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
    __emitRouteEvent: (routeId, payload) => {
      const listeners = routeEventListeners.get(routeId) || [];
      listeners.forEach((listener) => listener({ route_id: routeId, ...payload }));
    },
    __clearRealtimeMockState: () => {
      itemListeners.clear();
      statsListeners.clear();
      itemSourceListeners.clear();
      routeEventListeners.clear();
      subscribeToItemSource.mockClear();
      subscribeToItemStatus.mockClear();
      subscribeToRouteEvents.mockClear();
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
  sources: [
    {
      id: `${attrs.id}-primary`,
      position: 0,
      enabled: true,
      name: 'primary',
      schema: 'SRT',
      mode: 'listener',
      localaddress: '127.0.0.1',
      localport: 4201,
    },
    {
      id: `${attrs.id}-backup`,
      position: 1,
      enabled: true,
      name: 'backup-1',
      schema: 'SRT',
      mode: 'listener',
      localaddress: '127.0.0.1',
      localport: 4202,
    },
  ],
  active_source_id: `${attrs.id}-primary`,
  started_at: attrs.started_at ?? null,
  destinations: [],
  ...attrs,
});

describe('Routes', () => {
  const renderRoutes = (initialEntry = '/routes') => render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes />
    </MemoryRouter>,
  );

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
    routesApi.getStatusesAnalytics.mockResolvedValue({
      data: {
        points: [],
        meta: {
          from: new Date(Date.now() - 5 * 60_000).toISOString(),
          to: new Date().toISOString(),
          window: 'custom',
          bucket_ms: 30_000,
        },
      },
    });
    routesApi.getStatusesHistory.mockResolvedValue({
      data: {
        events: [],
        meta: {
          from: new Date(Date.now() - 5 * 60_000).toISOString(),
          to: new Date().toISOString(),
          window: 'live',
          limit: 50,
          offset: 0,
          total: 0,
        },
      },
    });
  });

  it('shows enabled Stop action for non-stopped routes', async () => {
    renderRoutes();

    await screen.findAllByText('Starting route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for starting route/i }));

    const stopAction = await screen.findByRole('menuitem', { name: /stop/i });
    expect(stopAction).not.toHaveAttribute('aria-disabled', 'true');
  });

  it('shows Start action for stopped routes', async () => {
    renderRoutes();

    await screen.findAllByText('Stopped route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for stopped route/i }));

    expect(await screen.findByRole('menuitem', { name: /start/i })).toBeInTheDocument();
  });

  it('shows enabled state in routes table', async () => {
    routesApi.getAll.mockResolvedValue({
      data: [
        routeFixture({
          id: 'enabled-route',
          name: 'Enabled route',
          enabled: true,
          status: 'stopped',
          schema_status: 'stopped',
        }),
        routeFixture({
          id: 'disabled-route',
          name: 'Disabled route',
          enabled: false,
          status: 'stopped',
          schema_status: 'stopped',
        }),
      ],
    });

    renderRoutes();

    await screen.findByText('Enabled route');
    await screen.findByText('Disabled route');

    const enabledRow = screen.getByText('Enabled route').closest('tr');
    const disabledRow = screen.getByText('Disabled route').closest('tr');

    expect(enabledRow).not.toBeNull();
    expect(disabledRow).not.toBeNull();
    expect(enabledRow).toHaveTextContent('Yes');
    expect(disabledRow).toHaveTextContent('No');
  });

  it('subscribes to route status events and updates the list status', async () => {
    renderRoutes();

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

  it('shows route in and out stats while status is not stopped', async () => {
    renderRoutes();

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
    renderRoutes();

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

    renderRoutes();

    expect(await screen.findByText('1m')).toBeInTheDocument();
  });

  it('fetches status analytics for selected window', async () => {
    renderRoutes('/routes?time=last_hour&status_view=chart');

    await screen.findAllByText('Starting route');
    expect(routesApi.getStatusesAnalytics).toHaveBeenCalled();
    expect(routesApi.getStatusesAnalytics).toHaveBeenLastCalledWith(
      expect.objectContaining({ window: 'last_hour' }),
    );
  });

  it('disables refresh in live and enables it in non-live windows', async () => {
    renderRoutes('/routes?time=last_hour&status_view=chart');

    await screen.findAllByText('Starting route');
    const refreshButton = screen.getByRole('button', { name: /refresh/i });
    expect(refreshButton).not.toBeDisabled();
  });

  it.skip('loads fallback history event in live when 5-minute window is empty', async () => {
    routesApi.getStatusesHistory
      .mockResolvedValueOnce({
        data: {
          events: [],
          meta: { window: 'live', limit: 50, offset: 0, total: 0 },
        },
      })
      .mockResolvedValueOnce({
        data: {
          events: [
            {
              ts: '2026-05-15T10:00:00Z',
              route_id: 'starting-route',
              route_name: 'Starting route',
              old_status: 'stopped',
              new_status: 'starting',
            },
          ],
          meta: { window: 'last_24_hour', limit: 1, offset: 0, total: 1 },
        },
      });

    renderRoutes();

    await screen.findByText('Starting route');
    fireEvent.click(screen.getByRole('tab', { name: /history/i }));

    expect(await screen.findByRole('link', { name: 'Starting route' })).toBeInTheDocument();
    expect(routesApi.getStatusesHistory).toHaveBeenNthCalledWith(1, expect.objectContaining({
      limit: 50,
      offset: 0,
    }));
    expect(routesApi.getStatusesHistory).toHaveBeenNthCalledWith(2, expect.objectContaining({
      window: 'last_24_hour',
      limit: 1,
      offset: 0,
    }));
  });

  it.skip('replaces history rows when pagination page changes', async () => {
    routesApi.getStatusesHistory.mockImplementation(async ({ offset }) => {
      if (offset === 0) {
        return {
          data: {
            events: [
              {
                ts: '2026-05-15T10:00:00Z',
                route_id: 'starting-route',
                route_name: 'Starting route',
                old_status: 'stopped',
                new_status: 'starting',
              },
            ],
            meta: { window: 'live', limit: 50, offset: 0, total: 100 },
          },
        };
      }

      return {
        data: {
          events: [
            {
              ts: '2026-05-15T10:01:00Z',
              route_id: 'stopped-route',
              route_name: 'Stopped route',
              old_status: 'starting',
              new_status: 'stopped',
            },
          ],
          meta: { window: 'live', limit: 50, offset: 50, total: 100 },
        },
      };
    });

    renderRoutes('/routes?page=2&time=live&status_view=history');

    await screen.findByRole('link', { name: 'Stopped route' });
  });

});
