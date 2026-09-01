import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { Form } from 'antd';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import YoutubeInputFields from '../YoutubeInputFields';
import YoutubeHealthTab from '../YoutubeHealthTab';
import { youtubeApi, routesApi } from '../../../utils/api';
import * as realtime from '../../../utils/realtime';

vi.mock('../../../utils/api', () => ({
  youtubeApi: { inspect: vi.fn(), refresh: vi.fn() },
  routesApi: { getEndpointHealth: vi.fn() },
}));

vi.mock('../../../utils/realtime', () => ({
  subscribeToEndpointHealth: vi.fn(() => () => {}),
}));

describe('YouTube source UI', () => {
  beforeEach(() => vi.clearAllMocks());

  it('checks formats and still presents a saveable no-formats result', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({ data: { live: false, variants: [] } });
    render(<Form initialValues={{ youtube_url: 'https://www.youtube.com/watch?v=fixture' }}><YoutubeInputFields /></Form>);

    fireEvent.click(screen.getByRole('button', { name: /check/i }));
    await waitFor(() => expect(screen.getByText('URL checked; no formats are available yet')).toBeInTheDocument());
    expect(screen.getByText(/save the fallback policy/i)).toBeInTheDocument();
    expect(youtubeApi.inspect).toHaveBeenCalledWith('https://www.youtube.com/watch?v=fixture', 'best[height<=1080]');
  });

  it('keeps the bearer URL out of the address and separates announced and actual health', async () => {
    vi.mocked(routesApi.getEndpointHealth).mockResolvedValue({ data: { endpoints: [] } });
    render(
      <YoutubeHealthTab
        routeId="route-1"
        sources={[{
          id: 'source-1', schema: 'YOUTUBE', name: 'ISS',
          youtube_url: 'https://www.youtube.com/watch?v=fixture',
          youtube_media_info: { title: 'ISS feed', video: { codec: 'H.264', width: 1920, height: 1080, fps: 30 }, audio: { codec: 'AAC' } },
        }]}
        routeActive={false}
      />,
    );

    await waitFor(() => expect(screen.getByText('Announced by YouTube')).toBeInTheDocument());
    expect(screen.getByText('Actual from the pipeline')).toBeInTheDocument();
    expect(screen.getByText('ISS feed')).toBeInTheDocument();
    expect(screen.queryByText(/googlevideo|sig=|lsig=/i)).not.toBeInTheDocument();
    expect(realtime.subscribeToEndpointHealth).toHaveBeenCalledWith('route-1', expect.any(Function));
  });

  it('gives bot-check failures a cookies configuration message', async () => {
    const error = new Error('resolver failed') as Error & { payload: unknown };
    error.payload = { error: { code: 'BOT_CHECK_CHALLENGE', message: 'bot check' } };
    vi.mocked(youtubeApi.inspect).mockRejectedValue(error);
    render(<Form initialValues={{ youtube_url: 'https://youtu.be/fixture' }}><YoutubeInputFields /></Form>);

    fireEvent.click(screen.getByRole('button', { name: /check/i }));
    await waitFor(() => expect(screen.getByText(/YOUTUBE_COOKIES_PATH/i)).toBeInTheDocument());
  });
});

describe('YouTube health tab', () => {
  const baseSource = {
    id: 'source-1',
    schema: 'YOUTUBE',
    name: 'Test feed',
    youtube_url: 'https://www.youtube.com/watch?v=fixture',
    youtube_media_info: { title: 'Test feed' },
  };

  beforeEach(() => vi.clearAllMocks());

  const renderHealthTab = async (sources: typeof baseSource[], routeActive = true, healthData?: Record<string, unknown>) => {
    vi.mocked(routesApi.getEndpointHealth).mockResolvedValue({
      data: healthData ?? { endpoints: [] },
    });
    render(<YoutubeHealthTab routeId="route-1" sources={sources} routeActive={routeActive} />);
    await waitFor(() => expect(screen.getByText('Actual from the pipeline')).toBeInTheDocument());
  };

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

  it('renders combined bitrate and does not show separate bitrate labels', async () => {
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

  it('renders em dash for lanes missing bitrate_kbps', async () => {
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

  it('shows awaiting health instead of unknown when route is active without health record', async () => {
    await renderHealthTab([baseSource], true, { endpoints: [] });

    expect(screen.getAllByText('Awaiting health').length).toBeGreaterThan(0);
    expect(screen.queryByText('unknown')).not.toBeInTheDocument();
  });
});
