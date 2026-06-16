import { describe, it, expect, vi, beforeEach } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router-dom';
import type { ReactNode } from 'react';
import SystemNodeMetrics from '../SystemNodeMetrics';
import { interfacesApi, nodesApi } from '../../../utils/api';

vi.mock('recharts', () => {
  const Mock = ({ children }: { children?: ReactNode }) => children ?? null;
  return {
    ResponsiveContainer: Mock,
    LineChart: Mock,
    CartesianGrid: () => null,
    XAxis: () => null,
    YAxis: () => null,
    Line: ({ dataKey, name }: { dataKey?: string; name?: string }) => (
      <span data-testid={`line-${dataKey}`}>{name}</span>
    ),
    Tooltip: () => null,
  };
});

vi.mock('../../../utils/api', () => ({
  interfacesApi: {
    getAll: vi.fn(),
    getSystemInterfaces: vi.fn(),
  },
  nodesApi: {
    getAnalytics: vi.fn(),
  },
}));

describe('SystemNodeMetrics', () => {
  const renderPage = (query = 'time=live') => render(
    <MemoryRouter initialEntries={[`/system/nodes/hydra%40127.0.0.1?${query}`]}>
      <Routes>
        <Route path="/system/nodes/:id" element={<SystemNodeMetrics />} />
      </Routes>
    </MemoryRouter>,
  );

  const RouteTransitionHarness = () => {
    const navigate = useNavigate();
    return (
      <>
        <button type="button" onClick={() => navigate('/system/nodes/other%40127.0.0.1?time=live')}>
          Go other
        </button>
        <Routes>
          <Route path="/system/nodes/:id" element={<SystemNodeMetrics />} />
        </Routes>
      </>
    );
  };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(interfacesApi.getAll).mockResolvedValue({ data: [] });
    vi.mocked(interfacesApi.getSystemInterfaces).mockResolvedValue({ data: [] });
    vi.mocked(nodesApi.getAnalytics).mockResolvedValue({
      points: [
        {
          timestamp: '2026-06-16T12:00:00.000Z',
          cpu: 12,
          ram: 30,
          swap: 0,
          la_avg1: 0.1,
          la_avg5: 0.2,
          la_avg15: 0.3,
          storage_total_root: 1000,
          storage_used_root: 400,
          storage_free_root: 600,
          storage_total_L2RhdGE: 2000,
          storage_used_L2RhdGE: 1000,
          storage_free_L2RhdGE: 1000,
          storage_total_metadata_database: 2048,
          storage_used_metadata_database: 2048,
          storage_free_metadata_database: 0,
          storage_total_metrics_logs_database: 4096,
          storage_used_metrics_logs_database: 4096,
          storage_free_metrics_logs_database: 0,
        },
      ],
      meta: {
        from: '2026-06-16T11:55:00.000Z',
        to: '2026-06-16T12:00:00.000Z',
        bucket_ms: 10_000,
        storages: [
          { id: 'root', mountpoint: '/', type: 'mountpoint' },
          { id: 'L2RhdGE', mountpoint: '/data', type: 'mountpoint' },
          {
            id: 'metadata_database',
            mountpoint: 'Metadata Database',
            name: 'Metadata Database',
            type: 'database',
          },
          {
            id: 'metrics_logs_database',
            mountpoint: 'Metrics and Logs Database',
            name: 'Metrics and Logs Database',
            type: 'database',
          },
        ],
        databases: [
          {
            id: 'metadata_database',
            mountpoint: 'Metadata Database',
            name: 'Metadata Database',
            type: 'database',
          },
          {
            id: 'metrics_logs_database',
            mountpoint: 'Metrics and Logs Database',
            name: 'Metrics and Logs Database',
            type: 'database',
          },
        ],
        default_storage_id: 'root',
      },
    });
  });

  it('renders storage metrics and selects the default storage', async () => {
    renderPage();

    expect(await screen.findByText(/Storage: used 400 B, free 600 B, total 1000 B/)).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.getByText('/')).toBeInTheDocument();
    });
  });

  it('renders selected storages as separate series instead of aggregate totals', async () => {
    renderPage('time=live&storage=root,L2RhdGE');

    expect(await screen.findByTestId('line-storage_total_root')).toHaveTextContent('/ total');
    expect(screen.getByTestId('line-storage_total_L2RhdGE')).toHaveTextContent('/data total');
    expect(screen.queryByTestId('line-storage_total_selected')).not.toBeInTheDocument();
  });

  it('renders database size series outside the selected storage filter', async () => {
    renderPage('time=live&storage=root');

    expect(await screen.findByText(/Database size: Meta DB:/)).toBeInTheDocument();
    expect(screen.getByTestId('line-storage_used_metadata_database')).toHaveTextContent('Meta DB');
    expect(screen.getByTestId('line-storage_used_metrics_logs_database')).toHaveTextContent('Metrics+Logs DB');
  });

  it('falls back to default storage when the storage query param lists invalid ids', async () => {
    renderPage('time=live&storage=missing-id');

    expect(await screen.findByTestId('line-storage_total_root')).toBeInTheDocument();
    expect(screen.queryByTestId('line-storage_total_missing-id')).not.toBeInTheDocument();
  });

  it('falls back to default storage when the storage query param lists a database id', async () => {
    renderPage('time=live&storage=metadata_database');

    expect(await screen.findByTestId('line-storage_total_root')).toBeInTheDocument();
    expect(screen.queryByTestId('line-storage_total_metadata_database')).not.toBeInTheDocument();
  });

  it('clears stale storage selection when meta has no mountpoint storages', async () => {
    vi.mocked(nodesApi.getAnalytics).mockResolvedValue({
      points: [
        {
          timestamp: '2026-06-16T12:00:00.000Z',
          storage_used_metadata_database: 2048,
        },
      ],
      meta: {
        from: '2026-06-16T11:55:00.000Z',
        to: '2026-06-16T12:00:00.000Z',
        bucket_ms: 10_000,
        storages: [
          {
            id: 'metadata_database',
            mountpoint: 'Metadata Database',
            name: 'Metadata Database',
            type: 'database',
          },
        ],
        databases: [
          {
            id: 'metadata_database',
            mountpoint: 'Metadata Database',
            name: 'Metadata Database',
            type: 'database',
          },
        ],
        default_storage_id: null,
      },
    });

    renderPage('time=live&storage=root');

    await waitFor(() => {
      expect(screen.queryByTestId('line-storage_total_root')).not.toBeInTheDocument();
    });
  });

  it('reinitializes default storage selection when node id changes', async () => {
    render(
      <MemoryRouter initialEntries={['/system/nodes/hydra%40127.0.0.1?time=live&storage=root,L2RhdGE']}>
        <RouteTransitionHarness />
      </MemoryRouter>
    );

    expect(await screen.findByTestId('line-storage_total_L2RhdGE')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Go other' }));

    await waitFor(() => {
      expect(screen.getByTestId('line-storage_total_root')).toBeInTheDocument();
      expect(screen.queryByTestId('line-storage_total_L2RhdGE')).not.toBeInTheDocument();
    });
  });
});
