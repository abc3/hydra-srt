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
      getById: async () => ({
        data: {
          id: 'r1',
          name: 'Route 1',
          status: 'started',
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
              schema: 'UDP',
              schema_options: { host: '127.0.0.1', port: 9999 },
              updated_at: new Date().toISOString(),
            },
            {
              id: 'd2',
              name: 'Dest 2',
              schema: 'SRT',
              schema_options: { localaddress: '127.0.0.1', localport: 8888, mode: 'caller' },
              updated_at: new Date().toISOString(),
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
  it('Overview shows bitrate KPIs derived from stats payload', async () => {
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

    // 1000 B/s -> 8000 bps; worst dest is 10 B/s -> 80 bps
    expect(screen.getByText('Route Statistics (Overview)')).toBeInTheDocument();
    expect(screen.getAllByText(/Connected Callers/i).length).toBeGreaterThan(0);
    expect(screen.getByText(/8000|8,000/)).toBeInTheDocument();
    expect(screen.getByText(/80\b/)).toBeInTheDocument();
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
});

