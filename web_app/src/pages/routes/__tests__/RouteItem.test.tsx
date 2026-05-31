import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteItem from '../RouteItem';
import * as realtime from '../../../utils/realtime';
import { routesApi } from '../../../utils/api';

type RealtimeStatusListener = (payload: { item_id: string; status: string }) => void;
type RealtimeSourceListener = (payload: { item_id: string; active_source_id: string; last_switch_reason: string }) => void;
type RealtimeMockExports = typeof realtime & {
  __emitItemSource: (itemId: string, activeSourceId: string, reason?: string) => void;
  __emitItemStatus: (itemId: string, status: string) => void;
  __clearRealtimeMockState: () => void;
};

const realtimeMock = realtime as RealtimeMockExports;
const { subscribeToItemSource, subscribeToItemStatus } = realtimeMock;

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
      getPipelineLogs: vi.fn(async () => ({
        data: {
          logs: [],
          meta: { total: 0, window: 'last_hour' },
        },
      })),
      getPipelineLogsDistinct: vi.fn(async () => ({ data: [] })),
      getById: vi.fn(async () => ({
        data: {
          id: 'r1',
          name: 'Route 1',
          status: 'started',
          schema_status: 'processing',
          updated_at: new Date().toISOString(),
          enabled: true,
          schema: 'SRT',
          sources: [
            { id: 's1', position: 0, enabled: true, name: 'primary', mode: 'listener', localaddress: '127.0.0.1', localport: 1234 },
            { id: 's2', position: 1, enabled: true, name: 'backup', mode: 'caller', address: '127.0.0.1', port: 8888 },
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
              host: '127.0.0.1',
              port: 9999,
              updated_at: new Date().toISOString(),
            },
            {
              id: 'd2',
              name: 'Dest 2',
              enabled: false,
              status: 'processing',
              schema: 'SRT',
              mode: 'caller',
              address: '127.0.0.1',
              port: 8888,
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
  const itemListeners = new Map<string, RealtimeStatusListener[]>();
  const itemSourceListeners = new Map<string, RealtimeSourceListener[]>();
  const statsListeners = new Set<() => void>();

  const subscribeToItemStatus = vi.fn((itemId: string, listener: RealtimeStatusListener) => {
    const listeners = itemListeners.get(itemId) || [];
    listeners.push(listener);
    itemListeners.set(itemId, listeners);

    return vi.fn(() => {
      const current = itemListeners.get(itemId) || [];
      itemListeners.set(
        itemId,
        current.filter((saved: RealtimeStatusListener) => saved !== listener),
      );
    });
  });

  const subscribeToItemSource = vi.fn((itemId: string, listener: RealtimeSourceListener) => {
    const listeners = itemSourceListeners.get(itemId) || [];
    listeners.push(listener);
    itemSourceListeners.set(itemId, listeners);

    return vi.fn(() => {
      const current = itemSourceListeners.get(itemId) || [];
      itemSourceListeners.set(
        itemId,
        current.filter((saved: RealtimeSourceListener) => saved !== listener),
      );
    });
  });

  const emitItemStatus = (itemId: string, status: string) => {
    const listeners = itemListeners.get(itemId) || [];
    listeners.forEach((listener: RealtimeStatusListener) => listener({ item_id: itemId, status }));
  };

  const emitItemSource = (itemId: string, activeSourceId: string, reason = 'manual') => {
    const listeners = itemSourceListeners.get(itemId) || [];
    listeners.forEach((listener: RealtimeSourceListener) => listener({
      item_id: itemId,
      active_source_id: activeSourceId,
      last_switch_reason: reason,
    }));
  };

  const subscribeToStats = vi.fn(() => vi.fn());

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
    realtimeMock.__clearRealtimeMockState();
    vi.mocked(routesApi.getById).mockResolvedValue({
      data: {
        id: 'r1',
        name: 'Route 1',
        status: 'started',
        schema_status: 'processing',
        updated_at: new Date().toISOString(),
        enabled: true,
        schema: 'SRT',
        sources: [
          { id: 's1', position: 0, enabled: true, name: 'primary', mode: 'listener', localaddress: '127.0.0.1', localport: 1234 },
          { id: 's2', position: 1, enabled: true, name: 'backup', mode: 'caller', address: '127.0.0.1', port: 8888 },
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
            host: '127.0.0.1',
            port: 9999,
            updated_at: new Date().toISOString(),
          },
          {
            id: 'd2',
            name: 'Dest 2',
            enabled: false,
            status: 'processing',
            schema: 'SRT',
            mode: 'caller',
            address: '127.0.0.1',
            port: 8888,
            updated_at: new Date().toISOString(),
          },
        ],
      },
    });
    vi.mocked(routesApi.getAnalytics).mockResolvedValue({
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
    vi.mocked(routesApi.getPipelineLogs).mockResolvedValue({
      data: {
        logs: [],
        meta: { total: 0, window: 'last_hour' },
      },
    });
    vi.mocked(routesApi.getPipelineLogsDistinct).mockResolvedValue({ data: [] });
  });

  it('subscribes to route, source, and destination item status topics', async () => {
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
    expect(subscribeToItemStatus).toHaveBeenCalledWith('s1', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('s2', expect.any(Function));
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
      realtimeMock.__emitItemSource('r1', 's2', 'manual');
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
      realtimeMock.__emitItemStatus('r1', 'stopped');
      realtimeMock.__emitItemStatus('d1', 'failed');
    });

    expect(await screen.findByText('failed')).toBeInTheDocument();
    expect(screen.getAllByText('stopped').length).toBeGreaterThan(0);
  });

  it('updates source rows in endpoints table when item status targets a source id', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');

    await act(async () => {
      realtimeMock.__emitItemStatus('s2', 'reconnecting');
    });

    expect(screen.getByText('reconnecting')).toBeInTheDocument();
  });

  it('loads pipeline logs when Pipeline Logs tab is selected', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');

    await act(async () => {
      fireEvent.click(screen.getByRole('tab', { name: 'Pipeline Logs' }));
    });

    await waitFor(() => {
      expect(routesApi.getPipelineLogs).toHaveBeenCalledWith(
        'r1',
        expect.objectContaining({ limit: 50, offset: 0 }),
      );
    });
  });

  it('shows route enabled tag under route title', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Enabled: Yes')).toBeInTheDocument();
  });

  it('shows enabled state for source and destination rows in endpoints table', async () => {
    vi.mocked(routesApi.getById).mockResolvedValue({
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
          { id: 's2', position: 1, enabled: false, name: 'backup' },
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

    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');
    expect(screen.getByText('backup').closest('tr')).toHaveTextContent('No');
    expect(screen.getByText('Dest 1').closest('tr')).toHaveTextContent('Yes');
    expect(screen.getByText('Dest 2').closest('tr')).toHaveTextContent('No');
  });

});
