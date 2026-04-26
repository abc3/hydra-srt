import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import SystemPipelines from '../SystemPipelines';
import { subscribeToSystemPipelines } from '../../../utils/realtime';

vi.mock('../../../utils/api', () => ({
  systemPipelinesApi: {
    kill: vi.fn(async () => ({ success: true })),
  },
}));

vi.mock('../../../utils/realtime', () => ({
  subscribeToSystemPipelines: vi.fn(),
}));

const pipelineFixture = (attrs) => ({
  pid: attrs.pid,
  cpu: '0.5%',
  memory: '12 KB',
  memory_percent: '0.1%',
  memory_bytes: 12_288,
  swap_percent: '0.0%',
  swap_bytes: 0,
  user: 'sts',
  start_time: '2026-04-26T09:10:00',
  ...attrs,
});

describe('SystemPipelines', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    subscribeToSystemPipelines.mockImplementation((listener) => {
      listener({
        pipelines: [
          pipelineFixture({
            pid: 111,
            command:
              '/Users/sts/dev/hydra/_build/dev/lib/hydra_srt/priv/native/hydra_srt_pipeline route-1',
          }),
        ],
        routes: [
          { id: 'route-1', name: 'Main SRT route' },
          { id: 'route-10', name: 'Other route' },
        ],
      });

      return vi.fn();
    });
  });

  it('renders owner route name as a route link', async () => {
    render(<SystemPipelines />);

    const ownerLink = await screen.findByRole('link', { name: 'Main SRT route' });

    expect(ownerLink).toHaveAttribute('href', '#/routes/route-1');
    expect(screen.getByText('09:10 26/04/2026')).toBeInTheDocument();
  });

  it('matches owner route by exact command argument', async () => {
    subscribeToSystemPipelines.mockImplementation((listener) => {
      listener({
        pipelines: [
          pipelineFixture({
            pid: 222,
            command:
              '/Users/sts/dev/hydra/_build/dev/lib/hydra_srt/priv/native/hydra_srt_pipeline route-10',
          }),
        ],
        routes: [
          { id: 'route-1', name: 'Main SRT route' },
          { id: 'route-10', name: 'Other route' },
        ],
      });

      return vi.fn();
    });

    render(<SystemPipelines />);

    expect(await screen.findByRole('link', { name: 'Other route' })).toHaveAttribute(
      'href',
      '#/routes/route-10'
    );
    expect(screen.queryByRole('link', { name: 'Main SRT route' })).not.toBeInTheDocument();
  });

  it('unsubscribes from realtime updates on unmount', () => {
    const unsubscribe = vi.fn();

    subscribeToSystemPipelines.mockImplementation((listener) => {
      listener({
        pipelines: [
          pipelineFixture({
            pid: 111,
            command:
              '/Users/sts/dev/hydra/_build/dev/lib/hydra_srt/priv/native/hydra_srt_pipeline route-1',
          }),
        ],
        routes: [{ id: 'route-1', name: 'Main SRT route' }],
      });

      return unsubscribe;
    });

    const { unmount } = render(<SystemPipelines />);

    unmount();

    expect(unsubscribe).toHaveBeenCalled();
  });
});
