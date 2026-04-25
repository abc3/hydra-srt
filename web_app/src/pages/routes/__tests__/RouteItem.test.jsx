import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteItem from '../RouteItem';

let statsCallback;

vi.mock('phoenix', () => {
  return {
    Socket: class {
      connect() {}
      disconnect() {}
      channel() {
        return {
          join() {
            return {
              receive() {
                return this;
              },
            };
          },
          on(event, cb) {
            if (event === 'stats') statsCallback = cb;
          },
          off() {},
          leave() {},
        };
      }
    },
  };
});

vi.mock('../../../utils/auth', () => {
  return {
    getToken: () => 'Bearer test',
  };
});

vi.mock('../../../utils/api', () => {
  return {
    routesApi: {
      stop: async () => ({ data: { status: 'stopped' } }),
      start: async () => ({ data: { status: 'started' } }),
      getById: async () => ({
        data: {
          id: 'r1',
          name: 'Route 1',
          status: 'started',
          schema_status: 'processing',
          updated_at: new Date().toISOString(),
          enabled: true,
          exportStats: false,
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
          stats: {
            source: { bytes_in_per_sec: 1000, bytes_in_total: 5000 },
            destinations: [
              { id: 'd1', name: 'Dest 1', schema: 'UDP', bytes_out_per_sec: 10, bytes_out_total: 100 },
            ],
            'connected-callers': 1,
          },
          stats_history: [
            {
              id: 'rs1',
              inserted_at: new Date().toISOString(),
              stats: {
                source: { bytes_in_per_sec: 1000, bytes_in_total: 5000 },
                destinations: [
                  { id: 'd1', name: 'Dest 1', schema: 'UDP', bytes_out_per_sec: 10, bytes_out_total: 100 },
                ],
                'connected-callers': 1,
              },
            },
          ],
        },
      }),
    },
    destinationsApi: {
      delete: async () => ({ data: {} }),
    },
  };
});

describe('RouteItem stats tabs', () => {
  it('Overview no longer shows the route statistics card', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    // Emit a live stats payload to drive the UI
    await act(async () => {
      statsCallback?.({
        source: { bytes_in_per_sec: 1000, bytes_in_total: 5000 },
        destinations: [
          { id: 'd1', name: 'Dest 1', schema: 'UDP', bytes_out_per_sec: 10, bytes_out_total: 100 },
          { id: 'd2', name: 'Dest 2', schema: 'SRT', bytes_out_per_sec: 20, bytes_out_total: 200 },
        ],
        'connected-callers': 1,
      });
    });

    expect(screen.queryByText('Route Statistics (Overview)')).not.toBeInTheDocument();
    expect(screen.queryByTestId('kpi-source-bitrate')).not.toBeInTheDocument();
    expect(screen.queryByTestId('kpi-worst-dest-bitrate')).not.toBeInTheDocument();
  });

  it('Statistics tab shows per-destination live bitrate', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    await act(async () => {
      statsCallback?.({
        source: { bytes_in_per_sec: 1000, bytes_in_total: 5000 },
        destinations: [
          { id: 'd1', name: 'Dest 1', schema: 'UDP', bytes_out_per_sec: 10, bytes_out_total: 100 },
        ],
        'connected-callers': 1,
      });
    });

    fireEvent.click(screen.getByRole('tab', { name: 'Statistics' }));

    expect(screen.getByText('80 bps')).toBeInTheDocument(); // 10 B/s -> 80 bps
  });

  it('Statistics tab initializes from persisted stats returned by the route API', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    fireEvent.click(await screen.findByRole('tab', { name: 'Statistics' }));

    expect(await screen.findByText('80 bps')).toBeInTheDocument();
    expect(screen.queryByText('Waiting for statistics...')).not.toBeInTheDocument();
  });

  it('updates status tag when schema_status arrives via Phoenix Channel', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1']}>
        <Routes>
          <Route path="/routes/:id" element={<RouteItem />} />
        </Routes>
      </MemoryRouter>,
    );

    // Wait for initial render (route schema_status 'processing' is visible)
    expect(await screen.findAllByText('Processing')).not.toHaveLength(0);

    // Live stats push carrying a new schema_status
    await act(async () => {
      statsCallback?.({ schema_status: 'reconnecting', 'connected-callers': 0 });
    });

    expect(screen.getAllByText('Reconnecting').length).toBeGreaterThanOrEqual(2);
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

    expect(screen.getAllByText('Processing').length).toBeGreaterThan(0);
  });

  it('does not let live stats overwrite local stopping state after Stop is clicked', async () => {
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

    expect(await screen.findAllByText('Stopping')).not.toHaveLength(0);

    await act(async () => {
      statsCallback?.({ schema_status: 'processing', 'connected-callers': 1 });
    });

    expect(screen.getAllByText('Stopping').length).toBeGreaterThan(0);
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
    expect(screen.getAllByText('Processing').length).toBeGreaterThanOrEqual(3);
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
});
