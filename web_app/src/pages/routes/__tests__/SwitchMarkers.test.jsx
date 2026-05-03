import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import SwitchMarkers from '../SwitchMarkers';

vi.mock('recharts', () => ({
  ReferenceLine: ({ x }) => <div data-testid="switch-marker">{x}</div>,
}));

describe('SwitchMarkers', () => {
  it('renders one marker per switch event at formatted timestamp', () => {
    const formatChartTimestamp = vi.fn((ts) => `fmt:${ts}`);

    render(
      <SwitchMarkers
        switches={[{ ts: '2026-05-01T12:00:00Z' }, { ts: '2026-05-01T12:10:00Z' }]}
        isLiveWindow={false}
        formatChartTimestamp={formatChartTimestamp}
      />,
    );

    expect(screen.getAllByTestId('switch-marker')).toHaveLength(2);
    expect(screen.getByText('fmt:2026-05-01T12:00:00Z')).toBeInTheDocument();
    expect(screen.getByText('fmt:2026-05-01T12:10:00Z')).toBeInTheDocument();
  });
});
