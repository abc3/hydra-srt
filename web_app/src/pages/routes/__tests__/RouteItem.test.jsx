import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteItem from '../RouteItem';
import { subscribeToItemStatus, __emitItemStatus, __clearRealtimeMockState } from '../../../utils/realtime';
import { routesApi } from '../../../utils/api';

vi.mock('../../../utils/api', () => {
  return {
    routesApi: {
      stop: async () => ({ data: { status: 'stopped' } }),
      start: async () => ({ data: { status: 'started' } }),
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
    },
    destinationsApi: {
      delete: async () => ({ data: {} }),
    },
  };
});

vi.mock('../../../utils/realtime', () => {
  const itemListeners = new Map();
  const unsubscribeFns = new Map();

  const subscribeToItemStatus = vi.fn((itemId, listener) => {
    const listeners = itemListeners.get(itemId) || [];
    listeners.push(listener);
    itemListeners.set(itemId, listeners);

    const unsubscribe = vi.fn(() => {
      const current = itemListeners.get(itemId) || [];
      itemListeners.set(
        itemId,
        current.filter((saved) => saved !== listener),
      );
    });

    unsubscribeFns.set(listener, unsubscribe);
    return unsubscribe;
  });

  const emitItemStatus = (itemId, status) => {
    const listeners = itemListeners.get(itemId) || [];
    listeners.forEach((listener) => listener({ item_id: itemId, status }));
  };

  return {
    subscribeToItemStatus,
    __emitItemStatus: emitItemStatus,
    __clearRealtimeMockState: () => {
      itemListeners.clear();
      unsubscribeFns.clear();
      subscribeToItemStatus.mockClear();
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

    expect(subscribeToItemStatus).toHaveBeenCalledWith('r1', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('d1', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('d2', expect.any(Function));
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

  it('switches Start button to Stop immediately after start click', async () => {
    routesApi.getById.mockResolvedValue({
      data: {
        id: 'r1',
        name: 'Route 1',
        status: 'stopped',
        schema_status: 'stopped',
        updated_at: new Date().toISOString(),
        enabled: true,
        schema: 'SRT',
        schema_options: { localaddress: '127.0.0.1', localport: 1234, mode: 'listener' },
        node: 'node@host',
        destinations: [],
      },
    });

    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    const startButton = await screen.findByRole('button', { name: /start/i });

    await act(async () => {
      fireEvent.click(startButton);
    });

    expect(await screen.findByRole('button', { name: /stop/i })).toBeInTheDocument();
  });

  it('does not show route statistics UI', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Endpoints')).toBeInTheDocument();
    expect(screen.queryByText('Route Metrics (Overview)')).not.toBeInTheDocument();
    expect(screen.queryByTestId('kpi-source-bitrate')).not.toBeInTheDocument();
    expect(screen.queryByTestId('kpi-worst-dest-bitrate')).not.toBeInTheDocument();
    expect(screen.queryByRole('tab', { name: 'Metrics' })).not.toBeInTheDocument();
  });

  it('keeps the current runtime status visible until refreshed after Stop is clicked', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    const stopButton = await screen.findByRole('button', { name: /stop/i });

    await act(async () => {
      fireEvent.click(stopButton);
    });

    expect(screen.getAllByText('running').length).toBeGreaterThan(0);
  });

  it('keeps local stopping state after Stop is clicked', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    const stopButton = await screen.findByRole('button', { name: /stop/i });

    await act(async () => {
      fireEvent.click(stopButton);
    });

    expect(await screen.findAllByText('stopping')).not.toHaveLength(0);

    expect(screen.getAllByText('stopping').length).toBeGreaterThan(0);
  });

  it('shows destination runtime status in the destinations table', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Status')).toBeInTheDocument();
    expect(screen.getAllByText('running').length).toBeGreaterThanOrEqual(3);
  });

  it('shows destination enabled state in the endpoints table', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Enabled')).toBeInTheDocument();
    expect(screen.getAllByText('Yes').length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText('No')).toBeInTheDocument();
  });

  it('disables route delete while the route is started', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    const deleteButtonLabel = await screen.findByText('Delete');
    const deleteButton = deleteButtonLabel.closest('button');
    expect(deleteButton).not.toBeNull();
    expect(deleteButton).toBeDisabled();
  });

  it('disables destination delete action while the route is started', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    const destinationActionsButton = await screen.findByRole('button', { name: 'Actions for Dest 1' });

    await act(async () => {
      fireEvent.click(destinationActionsButton);
    });

    const deleteLabels = await screen.findAllByText('Delete');
    const deleteMenuItem = deleteLabels.find((element) =>
      element.closest('[aria-disabled="true"]')
    );

    expect(deleteMenuItem).toBeTruthy();
    expect(deleteMenuItem.closest('[aria-disabled="true"]')).not.toBeNull();
  });

  it('shows a unified Endpoints table with Source first', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Endpoints')).toBeInTheDocument();
    expect(screen.getByText('Source')).toBeInTheDocument();
    expect(screen.getAllByText('Destination').length).toBeGreaterThan(0);

    const endpointLinks = screen.getAllByRole('link');
    expect(endpointLinks[0]).toHaveTextContent('Route 1');
  });

  it('unsubscribes from item topics on unmount', async () => {
    const { unmount } = render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Endpoints');

    const unsubs = subscribeToItemStatus.mock.results
      .map((result) => result.value)
      .filter((value) => typeof value === 'function');

    unmount();

    unsubs.forEach((unsubscribe) => {
      expect(unsubscribe).toHaveBeenCalledTimes(1);
    });
  });
});
