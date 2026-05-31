import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import ActiveSourceBadge from '../ActiveSourceBadge';

describe('ActiveSourceBadge', () => {
  it('renders primary source name with success color when active source is primary', () => {
    render(
      <ActiveSourceBadge
        route={{
          active_source_id: 's1',
          sources: [
            { id: 's1', position: 0, name: 'primary' },
            { id: 's2', position: 1, name: 'backup' },
          ],
        }}
      />,
    );

    expect(screen.getByText('primary')).toBeInTheDocument();
  });

  it('renders backup source name with warning color when active source is not primary', () => {
    render(
      <ActiveSourceBadge
        route={{
          active_source_id: 's2',
          sources: [
            { id: 's1', position: 0, name: 'primary' },
            { id: 's2', position: 1, name: 'backup-1' },
          ],
        }}
      />,
    );

    expect(screen.getByText('backup-1')).toBeInTheDocument();
  });
});
