import { render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import NdiHealthTab from '../NdiHealthTab';
import * as ndiApiModule from '../../../utils/ndiApi';
import * as realtime from '../../../utils/realtime';

vi.mock('../../../utils/ndiApi', () => ({
  ndiApi: {
    getEndpointHealth: vi.fn(),
    probe: vi.fn(),
  },
}));

vi.mock('../../../utils/realtime', () => ({
  subscribeToEndpointHealth: vi.fn(() => () => {}),
}));

vi.mock('../../../utils/api', () => ({
  routesApi: {
    getById: vi.fn(async () => ({ data: { id: 'r1' } })),
  },
}));

describe('NdiHealthTab', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('subscribes first then applies snapshot and shows endpoint cards', async () => {
    const subscribeOrder: string[] = [];
    vi.mocked(realtime.subscribeToEndpointHealth).mockImplementation(() => {
      subscribeOrder.push('subscribe');
      return () => {};
    });
    vi.mocked(ndiApiModule.ndiApi.getEndpointHealth).mockImplementation(async () => {
      subscribeOrder.push('snapshot');
      return {
        data: {
          generated_at: '2026-07-19T00:00:00Z',
          config_revision: 'rev-1',
          process_instance_id: 'proc-1',
          last_sequence: 2,
          endpoints: [
            {
              endpoint_id: 's1',
              direction: 'source',
              state: 'streaming',
              reason_code: null,
              sequence: 2,
              last_video_buffer_age_ms: 40,
              skew_ms: 1,
              drops: 0,
              reconnect_attempts: 0,
            },
          ],
        },
      };
    });

    render(
      <NdiHealthTab
        routeId="r1"
        sources={[{ id: 's1', name: 'Cam', schema: 'NDI', ndi_source_name: 'CAM (A)' }]}
        destinations={[{ id: 'd1', name: 'Out', schema: 'NDI', ndi_sender_name: 'Hydra (Out)' }]}
        activeSourceId="s1"
        routeActive
      />,
    );

    await waitFor(() => {
      expect(screen.getByText('CAM (A)')).toBeInTheDocument();
    });

    expect(screen.getByText('Hydra (Out)')).toBeInTheDocument();
    expect(screen.getByText('Active source')).toBeInTheDocument();
    expect(subscribeOrder[0]).toBe('subscribe');
    expect(subscribeOrder).toContain('snapshot');
    expect(realtime.subscribeToEndpointHealth).toHaveBeenCalledWith('r1', expect.any(Function));
  });

  it('shows empty state when the route has no NDI endpoints', () => {
    render(
      <NdiHealthTab
        routeId="r1"
        sources={[{ id: 's1', schema: 'SRT' }]}
        destinations={[{ id: 'd1', schema: 'UDP' }]}
      />,
    );

    expect(screen.getByText('This route has no NDI endpoints')).toBeInTheDocument();
  });
});
