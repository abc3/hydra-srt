import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import SrtHealthTab from '../SrtHealthTab';

describe('SrtHealthTab', () => {
  it('groups SRT endpoints and shows active source health', async () => {
    render(
      <SrtHealthTab
        sources={[{ id: 's1', name: 'Primary SRT', schema: 'SRT' }]}
        destinations={[
          { id: 'd1', name: 'SRT Output', schema: 'SRT' },
          { id: 'd2', name: 'UDP Output', schema: 'UDP' },
        ]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[{
          timestamp: '2026-07-02T20:00:00Z',
          entity_type: 'source',
          entity_id: 's1',
          rtt_ms: 12,
          packet_loss_percent: 0.25,
          negotiated_latency_ms: 120,
          bandwidth_mbps: 8,
          rate_mbps: 2,
          retransmitted_packets_per_sec: 3,
          dropped_packets_per_sec: 1,
          nack_packets_per_sec: 2,
        }]}
      />,
    );

    expect(screen.getByText('Quality')).toBeInTheDocument();
    expect(screen.getByText('Recovery')).toBeInTheDocument();
    expect(screen.getByText('12')).toBeInTheDocument();
    expect(screen.getByText('Estimated bandwidth').closest('.ant-statistic')).toHaveTextContent(
      '8.00Mbps',
    );
    expect(screen.getByText('Receive rate and estimated bandwidth')).toBeInTheDocument();
    expect(screen.getByText('Rate left · bandwidth right (Mbps)')).toBeInTheDocument();

    fireEvent.mouseEnter(screen.getAllByLabelText('About RTT')[0]);
    expect(
      await screen.findByText(/Smoothed round-trip time \(SRTT\)/),
    ).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'More' })).toHaveAttribute(
      'href',
      'https://github.com/Haivision/srt/blob/master/docs/API/statistics.md#msrtt',
    );

    fireEvent.mouseDown(screen.getByRole('combobox', { name: 'SRT endpoint' }));
    expect(screen.getByText('Sources')).toBeInTheDocument();
    expect(screen.getByText('Destinations')).toBeInTheDocument();
    expect(screen.queryByText('UDP Output')).not.toBeInTheDocument();
  });

  it('hides current metrics when the route is stopped but keeps chart history', () => {
    render(
      <SrtHealthTab
        sources={[{ id: 's1', name: 'Primary SRT', schema: 'SRT' }]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        routeActive={false}
        points={[{
          timestamp: '2026-07-02T20:00:00Z',
          entity_type: 'source',
          entity_id: 's1',
          rtt_ms: 12,
          packet_loss_percent: 0.25,
        }]}
      />,
    );

    expect(screen.getByText(/Route is stopped/)).toBeInTheDocument();
    expect(screen.getByText('Quality')).toBeInTheDocument();
    expect(screen.queryByText('12')).not.toBeInTheDocument();
  });

  it('shows an empty state when the route has no SRT endpoints', () => {
    render(
      <SrtHealthTab
        sources={[{ id: 's1', schema: 'RTMP' }]}
        destinations={[{ id: 'd1', schema: 'UDP' }]}
        loading={false}
        error={null}
        points={[]}
      />,
    );

    expect(screen.getByText('This route has no SRT endpoints')).toBeInTheDocument();
  });

  it('switches the link estimate to Gbps once it leaves stream range', () => {
    // SRT reports link capacity in Mbps; on a LAN that is thousands, which reads as a
    // broken axis next to a single-digit send rate.
    render(
      <SrtHealthTab
        sources={[{ id: 's1', name: 'Primary SRT', schema: 'SRT' }]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[{
          timestamp: '2026-07-02T20:00:00Z',
          entity_type: 'source',
          entity_id: 's1',
          bandwidth_mbps: 2285.72,
          rate_mbps: 4,
        }]}
      />,
    );

    // antd's Statistic truncates at the requested precision rather than rounding.
    expect(screen.getByText('Estimated bandwidth').closest('.ant-statistic')).toHaveTextContent(
      '2.28Gbps',
    );
    expect(screen.getByText('Rate left · bandwidth right (Gbps)')).toBeInTheDocument();
  });
});
