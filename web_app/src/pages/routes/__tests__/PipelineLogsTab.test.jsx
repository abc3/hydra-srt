import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import PipelineLogsTab from '../PipelineLogsTab';
import { routesApi } from '../../../utils/api';

vi.mock('../../../utils/api', () => ({
  routesApi: {
    getPipelineLogs: vi.fn(),
    getPipelineLogsDistinct: vi.fn(),
  },
}));

describe('PipelineLogsTab', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    routesApi.getPipelineLogs.mockResolvedValue({
      data: {
        logs: [
          {
            ts: '2026-05-01T12:00:00.123Z',
            level: 'WARN',
            category: 'srt',
            element: 'srt-src',
            message: 'connection failed',
          },
        ],
        meta: { total: 1 },
      },
    });
    routesApi.getPipelineLogsDistinct.mockResolvedValue({ data: ['WARN', 'ERROR'] });
  });

  it('renders pipeline log rows when active', async () => {
    render(
      <PipelineLogsTab
        routeId="r1"
        active
        analyticsWindow="last_hour"
        customRangeApplied={[]}
        refreshTick={0}
      />,
    );

    await waitFor(() => {
      expect(routesApi.getPipelineLogs).toHaveBeenCalledWith(
        'r1',
        expect.objectContaining({ window: 'last_hour', limit: 50, offset: 0 }),
      );
    });

    expect(screen.getByText('WARN')).toBeInTheDocument();
    expect(screen.getByText('srt')).toBeInTheDocument();
    expect(screen.getByText('connection failed')).toBeInTheDocument();
    expect(screen.getByText('1 logs')).toBeInTheDocument();
  });

  it('does not fetch logs when inactive', async () => {
    render(
      <PipelineLogsTab
        routeId="r1"
        active={false}
        analyticsWindow="last_hour"
        customRangeApplied={[]}
        refreshTick={0}
      />,
    );

    await waitFor(() => {
      expect(routesApi.getPipelineLogs).not.toHaveBeenCalled();
    });
  });
});
