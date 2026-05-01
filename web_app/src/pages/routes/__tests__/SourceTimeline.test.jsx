import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import SourceTimeline from '../SourceTimeline';

describe('SourceTimeline', () => {
  it('renders timeline segments with source labels and time ranges', () => {
    const formatChartTimestamp = vi.fn((value) => value.slice(11, 19));

    render(
      <SourceTimeline
        sourceTimeline={[
          {
            source_id: 's1',
            from: '2026-05-01T12:00:00Z',
            to: '2026-05-01T12:05:00Z',
          },
          {
            source_id: 's2',
            from: '2026-05-01T12:05:00Z',
            to: '2026-05-01T12:10:00Z',
          },
        ]}
        sourceNameById={{ s1: 'Primary', s2: 'Backup' }}
        formatChartTimestamp={formatChartTimestamp}
      />,
    );

    expect(screen.getByText('Source Timeline:')).toBeInTheDocument();
    expect(screen.getByText(/Primary:/)).toBeInTheDocument();
    expect(screen.getByText(/Backup:/)).toBeInTheDocument();
  });
});
