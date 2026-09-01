import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { RouteEndpoint } from '../../../types/routes';
import YoutubeHealthTab, { formatCombinedBitrate } from '../YoutubeHealthTab';
import { routesApi } from '../../../utils/api';
import * as realtime from '../../../utils/realtime';

vi.mock('../../../utils/api', () => ({
  routesApi: { getEndpointHealth: vi.fn() },
}));

vi.mock('../../../utils/realtime', () => ({
  subscribeToEndpointHealth: vi.fn(() => () => {}),
}));

describe('YoutubeHealthTab', () => {
  const baseSource: RouteEndpoint = {
    id: 'source-1',
    schema: 'YOUTUBE',
    name: 'Test feed',
    youtube_url: 'https://www.youtube.com/watch?v=fixture',
    youtube_media_info: { title: 'Test feed' },
  };

  beforeEach(() => vi.clearAllMocks());

  const renderHealthTab = async (
    sources: RouteEndpoint[],
    routeActive = true,
    healthData?: Record<string, unknown>,
  ) => {
    vi.mocked(routesApi.getEndpointHealth).mockResolvedValue({
      data: healthData ?? { endpoints: [] },
    });
    render(<YoutubeHealthTab routeId="route-1" sources={sources} routeActive={routeActive} />);
    await waitFor(() => expect(screen.getByText('Actual from the pipeline')).toBeInTheDocument());
  };

  it('shows an empty state when the route has no youtube sources', () => {
    render(
      <YoutubeHealthTab
        routeId="route-1"
        sources={[{ id: 'source-1', schema: 'SRT', name: 'SRT source' }]}
      />,
    );

    expect(screen.getByText('This route has no YouTube sources')).toBeInTheDocument();
  });

  it('shows a load error with retry and recovers on retry', async () => {
    vi.mocked(routesApi.getEndpointHealth)
      .mockRejectedValueOnce(new Error('network down'))
      .mockResolvedValueOnce({
        data: {
          endpoints: [{ endpoint_id: 'source-1', state: 'streaming' }],
        },
      });

    render(<YoutubeHealthTab routeId="route-1" sources={[baseSource]} />);

    await waitFor(() => {
      expect(screen.getByText('network down')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: /^retry$/i }));

    await waitFor(() => {
      expect(screen.getAllByText('streaming').length).toBeGreaterThan(0);
    });
    expect(routesApi.getEndpointHealth).toHaveBeenCalledTimes(2);
  });

  it('shows a stopped-route notice while still rendering persisted metadata', async () => {
    await renderHealthTab(
      [{
        ...baseSource,
        youtube_live_mode: false,
        youtube_format_id: '137',
        youtube_info_updated_at: '2026-01-01T00:00:00.000Z',
      }],
      false,
      { endpoints: [] },
    );

    expect(screen.getByText('Route is stopped')).toBeInTheDocument();
    expect(screen.getByText(/persisted YouTube metadata/i)).toBeInTheDocument();
    expect(screen.getAllByText('stopped').length).toBeGreaterThan(0);
    expect(screen.getByText(/Selected quality:/).parentElement).toHaveTextContent('137');
  });

  it('shows vod live status from the endpoint when health has no live flag', async () => {
    await renderHealthTab(
      [{ ...baseSource, youtube_live_mode: false }],
      true,
      { endpoints: [{ endpoint_id: 'source-1', state: 'streaming' }] },
    );

    const announced = screen.getByText('Announced by YouTube').closest('.ant-card');
    expect(announced).not.toBeNull();
    expect(within(announced as HTMLElement).getByText('VOD')).toBeInTheDocument();
  });

  it('shows live status from the health record over the endpoint snapshot', async () => {
    await renderHealthTab(
      [{ ...baseSource, youtube_live_mode: false }],
      true,
      {
        endpoints: [{
          endpoint_id: 'source-1',
          state: 'streaming',
          youtube_live_mode: true,
        }],
      },
    );

    const announced = screen.getByText('Announced by YouTube').closest('.ant-card');
    expect(announced).not.toBeNull();
    expect(within(announced as HTMLElement).getByText('Live')).toBeInTheDocument();
  });

  it('replaces snapshot health when a realtime update arrives', async () => {
    let onHealth: ((payload: unknown) => void) | undefined;
    vi.mocked(realtime.subscribeToEndpointHealth).mockImplementation((_routeId, callback) => {
      onHealth = callback as (payload: unknown) => void;
      return () => {};
    });
    vi.mocked(routesApi.getEndpointHealth).mockResolvedValue({
      data: {
        endpoints: [{
          endpoint_id: 'source-1',
          state: 'reconnecting',
          youtube_live_mode: false,
        }],
      },
    });

    render(<YoutubeHealthTab routeId="route-1" sources={[baseSource]} />);
    await waitFor(() => expect(screen.getAllByText('reconnecting').length).toBeGreaterThan(0));

    act(() => {
      onHealth?.({
        endpoint_id: 'source-1',
        state: 'streaming',
        youtube_live_mode: true,
        youtube_info_updated_at: '2026-07-01T08:00:00.000Z',
      });
    });

    await waitFor(() => {
      expect(screen.getAllByText('streaming').length).toBeGreaterThan(0);
    });
    const announced = screen.getByText('Announced by YouTube').closest('.ant-card');
    expect(within(announced as HTMLElement).getByText('Live')).toBeInTheDocument();
  });

  it('formats observed timestamps and keeps unparseable values visible', async () => {
    await renderHealthTab(
      [{
        ...baseSource,
        youtube_info_updated_at: 'not-a-timestamp',
      }],
      true,
      {
        endpoints: [{
          endpoint_id: 'source-1',
          state: 'streaming',
          youtube_info_updated_at: '2026-06-15T10:30:00.000Z',
        }],
      },
    );

    expect(screen.getByText(/Observed/)).toHaveTextContent('Observed');
    expect(screen.getByText(/Observed.*2026/)).toBeInTheDocument();
    expect(screen.queryByText(/Observed not-a-timestamp/)).not.toBeInTheDocument();
  });

  it('shows an unparseable observed timestamp from the endpoint when health has none', async () => {
    await renderHealthTab(
      [{
        ...baseSource,
        youtube_info_updated_at: 'not-a-timestamp',
      }],
      true,
      { endpoints: [{ endpoint_id: 'source-1', state: 'streaming' }] },
    );

    expect(screen.getByText(/Observed not-a-timestamp/)).toBeInTheDocument();
  });

  it('renders caps object as a human string without raw JSON', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{
        endpoint_id: 'source-1',
        state: 'streaming',
        video: { codec: 'H.264', width: 1280, height: 720, fps: 30 },
      }],
    });

    expect(screen.getByText('H.264 1280×720 @30')).toBeInTheDocument();
    expect(screen.queryByText(/\{"codec"/)).not.toBeInTheDocument();
  });

  it('renders partial caps with codec only and no stray separators', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{
        endpoint_id: 'source-1',
        state: 'streaming',
        video: { codec: 'H.264' },
      }],
    });

    expect(screen.getByText('H.264')).toBeInTheDocument();
    expect(screen.queryByText(/H\.264 ×/)).not.toBeInTheDocument();
    expect(screen.queryByText(/@/)).not.toBeInTheDocument();
  });

  it('renders em dash when caps are missing', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{ endpoint_id: 'source-1', state: 'streaming' }],
    });

    const pipeline = screen.getByText('Actual from the pipeline').closest('.ant-card');
    expect(pipeline).not.toBeNull();
    expect(within(pipeline as HTMLElement).getByText(/Caps:/).parentElement).toHaveTextContent('Caps: —');
  });

  it('renders combined bitrate when both lanes are measured', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{
        endpoint_id: 'source-1',
        state: 'streaming',
        video: { codec: 'H.264', bitrate_kbps: 650 },
        audio: { codec: 'AAC', bitrate_kbps: 948 },
      }],
    });

    const pipeline = screen.getByText('Actual from the pipeline').closest('.ant-card');
    expect(pipeline).not.toBeNull();
    expect(within(pipeline as HTMLElement).getByText(/Bitrate:/).parentElement)
      .toHaveTextContent('Bitrate: Video 650kbps / Audio 948kbps');
    expect(screen.queryByText('Video bitrate')).not.toBeInTheDocument();
    expect(screen.queryByText('Audio bitrate')).not.toBeInTheDocument();
  });

  it('renders video-only bitrate without a stray separator', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{
        endpoint_id: 'source-1',
        state: 'streaming',
        video: { codec: 'H.264', bitrate_kbps: 650 },
      }],
    });

    const pipeline = screen.getByText('Actual from the pipeline').closest('.ant-card');
    expect(pipeline).not.toBeNull();
    expect(within(pipeline as HTMLElement).getByText(/Bitrate:/).parentElement)
      .toHaveTextContent('Bitrate: Video 650kbps');
    expect(within(pipeline as HTMLElement).queryByText(/\//)).not.toBeInTheDocument();
  });

  it('renders audio-only bitrate without a stray separator', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{
        endpoint_id: 'source-1',
        state: 'streaming',
        audio: { codec: 'AAC', bitrate_kbps: 130 },
      }],
    });

    const pipeline = screen.getByText('Actual from the pipeline').closest('.ant-card');
    expect(pipeline).not.toBeNull();
    expect(within(pipeline as HTMLElement).getByText(/Bitrate:/).parentElement)
      .toHaveTextContent('Bitrate: Audio 130kbps');
    expect(within(pipeline as HTMLElement).queryByText(/\//)).not.toBeInTheDocument();
  });

  it('renders em dash when neither lane has a measured bitrate', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{ endpoint_id: 'source-1', state: 'streaming' }],
    });

    const pipeline = screen.getByText('Actual from the pipeline').closest('.ant-card');
    expect(pipeline).not.toBeNull();
    expect(within(pipeline as HTMLElement).getByText(/Bitrate:/).parentElement).toHaveTextContent('Bitrate: —');
  });

  it('renders em dash when lanes exist but lack bitrate_kbps', async () => {
    await renderHealthTab([baseSource], true, {
      endpoints: [{
        endpoint_id: 'source-1',
        state: 'streaming',
        video: { codec: 'H.264' },
        audio: { codec: 'AAC' },
      }],
    });

    const pipeline = screen.getByText('Actual from the pipeline').closest('.ant-card');
    expect(pipeline).not.toBeNull();
    expect(within(pipeline as HTMLElement).getByText(/Bitrate:/).parentElement).toHaveTextContent('Bitrate: —');
    expect(screen.queryByText('0')).not.toBeInTheDocument();
  });

  describe('formatCombinedBitrate', () => {
    it('formats both lanes with the exact combined shape', () => {
      expect(formatCombinedBitrate({ bitrate_kbps: 650 }, { bitrate_kbps: 948 }))
        .toBe('Video 650kbps / Audio 948kbps');
    });

    it('formats video only without a separator', () => {
      expect(formatCombinedBitrate({ bitrate_kbps: 650 }, null)).toBe('Video 650kbps');
    });

    it('formats audio only without a separator', () => {
      expect(formatCombinedBitrate(null, { bitrate_kbps: 130 })).toBe('Audio 130kbps');
    });

    it('returns em dash when neither lane is measured', () => {
      expect(formatCombinedBitrate(null, null)).toBe('—');
      expect(formatCombinedBitrate({ codec: 'H.264' }, { codec: 'AAC' })).toBe('—');
    });
  });

  it('shows awaiting health instead of unknown when route is active without health record', async () => {
    await renderHealthTab([baseSource], true, { endpoints: [] });

    expect(screen.getAllByText('Awaiting health').length).toBeGreaterThan(0);
    expect(screen.queryByText('unknown')).not.toBeInTheDocument();
  });
});
