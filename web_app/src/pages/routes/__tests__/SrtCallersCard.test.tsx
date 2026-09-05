import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import SrtCallersCard from '../SrtCallersCard';
import { routesApi } from '../../../utils/api';
import { callerLabelsApi } from '../../../utils/callerLabelsApi';
import { subscribeToStats } from '../../../utils/realtime';

vi.mock('../../../utils/api', () => ({
  routesApi: {
    getSrtCallers: vi.fn(),
    banSrtCaller: vi.fn(),
  },
}));

vi.mock('../../../utils/callerLabelsApi', () => ({
  callerLabelsApi: {
    list: vi.fn(),
  },
}));

vi.mock('../../../utils/realtime', () => ({
  subscribeToStats: vi.fn(),
}));

const sampleCaller = {
  'caller-address': '203.0.113.5:41234',
  'stream-id': 'studio-a',
  'rtt-ms': 12.4,
  'receive-rate-mbps': 8.25,
  'packet-loss-percent': null,
  'retransmitted-packets-per-sec': 2,
  'dropped-packets-per-sec': 1,
  connected_at: '2026-09-03T10:00:00Z',
  duration_seconds: 95,
  label: null,
};

describe('SrtCallersCard', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(subscribeToStats).mockReturnValue(() => undefined);
    vi.mocked(callerLabelsApi.list).mockResolvedValue({ data: [] });
    vi.mocked(routesApi.getSrtCallers).mockResolvedValue({ data: [sampleCaller] });
    vi.mocked(routesApi.banSrtCaller).mockResolvedValue({
      data: {
        endpoint_id: 'endpoint-1',
        limit_access: true,
        denied_list: ['203.0.113.5'],
      },
    });
  });

  it('renders a caller row with an em dash for null metrics and no label fallback text', async () => {
    render(<SrtCallersCard routeId="route-1" routeActive />);

    await waitFor(() => {
      expect(routesApi.getSrtCallers).toHaveBeenCalledWith('route-1');
    });

    const row = screen.getByText('203.0.113.5:41234').closest('tr');
    expect(row).not.toBeNull();

    const cells = within(row as HTMLElement).getAllByRole('cell');
    expect(cells[1]).toHaveTextContent('—');
    expect(cells[5]).toHaveTextContent('—');
    expect(cells[2]).toHaveTextContent('studio-a');
    expect(cells[8]).toHaveTextContent('8.25 Mbps');
  });

  it('bans the caller IP on confirmation', async () => {
    render(<SrtCallersCard routeId="route-1" routeActive />);

    await waitFor(() => {
      expect(screen.getByText('203.0.113.5:41234')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: 'Ban' }));
    const banButtons = await screen.findAllByRole('button', { name: 'Ban' });
    fireEvent.click(banButtons[banButtons.length - 1]);

    await waitFor(() => {
      expect(routesApi.banSrtCaller).toHaveBeenCalledWith('route-1', '203.0.113.5');
    });
  });
});
