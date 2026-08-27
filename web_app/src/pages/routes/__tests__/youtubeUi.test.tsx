import { fireEvent, render, screen, waitFor } from '@testing-library/react';
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
