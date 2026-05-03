import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import EventsLog from '../EventsLog';

describe('EventsLog', () => {
  it('renders filter control and events rows', () => {
    const onChange = vi.fn();

    render(
      <>
        <EventsLog.Filter value="" onChange={onChange} />
        <EventsLog
          eventsLoading={false}
          events={[
            {
              ts: '2026-05-01T12:00:00Z',
              event_type: 'source_switch',
              source_id: 's1',
              reason: 'manual',
              message: 'switched',
            },
          ]}
          sourceNameById={{ s1: 'Primary' }}
          formatLastUpdated={(value) => value}
        />
      </>,
    );

    expect(screen.getByText('source_switch')).toBeInTheDocument();
    expect(screen.getByText('Primary')).toBeInTheDocument();
    expect(screen.getByText('manual')).toBeInTheDocument();
    expect(screen.getByRole('combobox')).toBeInTheDocument();
  });
});
