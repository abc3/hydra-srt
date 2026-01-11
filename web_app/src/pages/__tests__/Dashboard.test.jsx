import { describe, it, expect, vi } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import Dashboard from '../Dashboard';

vi.mock('../../utils/auth', () => {
  return {
    getToken: () => 'Bearer test',
  };
});

vi.mock('../../utils/api', () => {
  return {
    dashboardApi: {
      getSummary: async () => ({
        routes: { total: 3, started: 1, stopped: 2, enabled: 2, disabled: 1 },
        nodes: { total: 1, up: 1, down: 0 },
        pipelines: { count: 4 },
        system: { cpu: 10, ram: 20, swap: 0, la: '0.1 / 0.2 / 0.3', host: 'self@host' },
        throughput: { in_bytes_per_sec: 100, out_bytes_per_sec: 50, routes_with_stats: 1 },
      }),
    },
    nodesApi: {
      getAll: async () => [
        { host: 'self@host', status: 'self', cpu: 10, ram: 20, swap: 0, la: '0.1 / 0.2 / 0.3' },
      ],
    },
  };
});

describe('Dashboard', () => {
  it('renders KPIs from summary', async () => {
    render(<Dashboard />);

    expect(await screen.findByText('Total Routes')).toBeInTheDocument();
    expect(screen.getByText('3')).toBeInTheDocument();

    expect(screen.getByText('Started Routes')).toBeInTheDocument();
    // "1" can appear multiple times (e.g. enabled-not-started, nodes counts), so scope the check
    const startedTitle = screen.getByText('Started Routes');
    const startedCard = startedTitle.closest('.ant-card');
    expect(startedCard).toBeTruthy();
    expect(within(startedCard).getByText('1')).toBeInTheDocument();

    expect(screen.getByText('Pipelines (OS)')).toBeInTheDocument();
    const pipelinesTitle = screen.getByText('Pipelines (OS)');
    const pipelinesCard = pipelinesTitle.closest('.ant-card');
    expect(pipelinesCard).toBeTruthy();
    expect(within(pipelinesCard).getByText('4')).toBeInTheDocument();
  });
});

