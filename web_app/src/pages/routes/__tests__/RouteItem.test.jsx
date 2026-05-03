import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteItem from '../RouteItem';
import {
  subscribeToItemSource,
  subscribeToItemStatus,
  subscribeToStats,
  __emitItemSource,
  __emitItemStatus,
  __clearRealtimeMockState,
} from '../../../utils/realtime';
import { routesApi } from '../../../utils/api';

vi.mock('../../../utils/api', () => {
  return {
    routesApi: {
      stop: async () => ({ data: { status: 'stopped' } }),
      start: async () => ({ data: { status: 'starting' } }),
      getAnalytics: vi.fn(async () => ({
        data: {
          points: [],
          switches: [],
          source_timeline: [],
          meta: {
            window: 'last_hour',
            bucket_ms: 10_000,
          },
        },
      })),
      getById: vi.fn(async () => ({
        data: {
          id: 'r1',
          name: 'Route 1',
          status: 'started',
          schema_status: 'processing',
          updated_at: new Date().toISOString(),
          enabled: true,
          schema: 'SRT',
          schema_options: { localaddress: '127.0.0.1', localport: 1234, mode: 'listener' },
          sources: [
            { id: 's1', position: 0, enabled: true, name: 'primary' },
            { id: 's2', position: 1, enabled: true, name: 'backup' },
          ],
          active_source_id: 's1',
          node: 'node@host',
          destinations: [
            {
              id: 'd1',
              name: 'Dest 1',
              enabled: true,
              status: 'processing',
              schema: 'UDP',
              schema_options: { host: '127.0.0.1', port: 9999 },
              updated_at: new Date().toISOString(),
            },
            {
              id: 'd2',
              name: 'Dest 2',
              enabled: false,
              status: 'processing',
              schema: 'SRT',
              schema_options: { localaddress: '127.0.0.1', localport: 8888, mode: 'caller' },
              updated_at: new Date().toISOString(),
            },
          ],
        },
      })),
      switchSource: vi.fn(async () => ({ data: { active_source_id: 's2', last_switch_reason: 'manual' } })),
    },
    sourcesApi: {
      test: vi.fn(async () => ({ data: { ok: true } })),
    },
    destinationsApi: {
      delete: async () => ({ data: {} }),
    },
  };
});

vi.mock('../../../utils/realtime', () => {
  const itemListeners = new Map();
  const itemSourceListeners = new Map();
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

  const emitItemStatus = (itemId, status) => {
    const listeners = itemListeners.get(itemId) || [];
    listeners.forEach((listener) => listener({ item_id: itemId, status }));
  };

  const emitItemSource = (itemId, activeSourceId, reason = 'manual') => {
    const listeners = itemSourceListeners.get(itemId) || [];
    listeners.forEach((listener) => listener({
      item_id: itemId,
      active_source_id: activeSourceId,
      last_switch_reason: reason,
    }));
  };

  const subscribeToStats = vi.fn((listener) => {
    if (typeof listener === 'function') {
      statsListeners.add(listener);
    }

    return vi.fn(() => {
      if (typeof listener === 'function') {
        statsListeners.delete(listener);
      }
    });
  });

  return {
    subscribeToItemSource,
    subscribeToItemStatus,
    subscribeToStats,
    __emitItemSource: emitItemSource,
    __emitItemStatus: emitItemStatus,
    __clearRealtimeMockState: () => {
      itemListeners.clear();
      itemSourceListeners.clear();
      statsListeners.clear();
      subscribeToItemSource.mockClear();
      subscribeToItemStatus.mockClear();
      subscribeToStats.mockClear();
    },
  };
});

describe('RouteItem', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    __clearRealtimeMockState();
    routesApi.getById.mockResolvedValue({
      data: {
        id: 'r1',
        name: 'Route 1',
        status: 'started',
        schema_status: 'processing',
        updated_at: new Date().toISOString(),
        enabled: true,
        schema: 'SRT',
        schema_options: { localaddress: '127.0.0.1', localport: 1234, mode: 'listener' },
        sources: [
          { id: 's1', position: 0, enabled: true, name: 'primary' },
          { id: 's2', position: 1, enabled: true, name: 'backup' },
        ],
        active_source_id: 's1',
        node: 'node@host',
        destinations: [
          {
            id: 'd1',
            name: 'Dest 1',
            enabled: true,
            status: 'processing',
            schema: 'UDP',
            schema_options: { host: '127.0.0.1', port: 9999 },
            updated_at: new Date().toISOString(),
          },
          {
            id: 'd2',
            name: 'Dest 2',
            enabled: false,
            status: 'processing',
            schema: 'SRT',
            schema_options: { localaddress: '127.0.0.1', localport: 8888, mode: 'caller' },
            updated_at: new Date().toISOString(),
          },
        ],
      },
    });
    routesApi.getAnalytics.mockResolvedValue({
      data: {
        points: [],
        switches: [],
        source_timeline: [],
        meta: {
          window: 'last_hour',
          bucket_ms: 10_000,
        },
      },
    });
  });

  it('subscribes to route and destination item status topics', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');
    expect(screen.getByText('Type')).toBeInTheDocument();
    expect(screen.getByText('Active')).toBeInTheDocument();

    expect(subscribeToItemStatus).toHaveBeenCalledWith('r1', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('d1', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('d2', expect.any(Function));
    expect(subscribeToItemSource).toHaveBeenCalledWith('r1', expect.any(Function));
  });

  it('updates active source indicator in endpoints table when item source event arrives', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');
    expect(screen.getAllByText('Active')).toHaveLength(1);

    await act(async () => {
      __emitItemSource('r1', 's2', 'manual');
    });

    expect(screen.getAllByText('Active')).toHaveLength(1);
    expect(screen.queryByText(/BACKUP:/)).not.toBeInTheDocument();
  });

  it('calls switch source from source actions', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Actions for backup' }));
    });

    await act(async () => {
      fireEvent.click(await screen.findByRole('menuitem', { name: /switch/i }));
    });

    expect(routesApi.switchSource).toHaveBeenCalledWith('r1', 's2');
  });

  it('updates statuses when item status events arrive', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');

    await act(async () => {
      __emitItemStatus('r1', 'stopped');
      __emitItemStatus('d1', 'failed');
    });

    expect(await screen.findByText('failed')).toBeInTheDocument();
    expect(screen.getAllByText('stopped').length).toBeGreaterThan(0);
  });

});
