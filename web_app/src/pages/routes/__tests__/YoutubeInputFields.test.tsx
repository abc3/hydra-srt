import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { Form, type FormInstance } from 'antd';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import YoutubeInputFields from '../YoutubeInputFields';
import type { YoutubeInspectData } from '../../../types/youtube';
import { youtubeApi } from '../../../utils/api';

vi.mock('../../../utils/api', () => ({
  youtubeApi: { inspect: vi.fn(), refresh: vi.fn() },
}));

describe('YoutubeInputFields', () => {
  let form: FormInstance;

  const renderFields = (initialValues: Record<string, unknown> = {}) => {
    const Wrapper = () => {
      const [formInstance] = Form.useForm();
      form = formInstance;
      return (
        <Form form={formInstance} initialValues={initialValues}>
          <YoutubeInputFields />
        </Form>
      );
    };
    return render(<Wrapper />);
  };

  const inspectVariants = {
    live: true,
    variants: [
      {
        format_id: '137',
        label: '1080p60 (H.264)',
        width: 1920,
        height: 1080,
        fps: 60,
        has_video: true,
        has_audio: true,
      },
      {
        format_id: '140',
        label: 'audio only (m4a)',
        has_audio: true,
      },
    ],
    media_info: {
      title: 'Fixture stream',
      video: { codec: 'H.264', width: 1920, height: 1080, fps: 60 },
      audio: { codec: 'AAC' },
      tbr: 4500,
    },
  };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(youtubeApi.refresh).mockResolvedValue({});
  });

  it('rejects an empty url locally without calling inspect', async () => {
    renderFields();

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText('Enter a valid YouTube watch URL.')).toBeInTheDocument();
    });
    expect(youtubeApi.inspect).not.toHaveBeenCalled();
  });

  it('rejects a non-youtube url locally without calling inspect', async () => {
    renderFields({ youtube_url: 'https://example.com/watch?v=123' });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText('Enter a valid YouTube watch URL.')).toBeInTheDocument();
    });
    expect(youtubeApi.inspect).not.toHaveBeenCalled();
  });

  it('keeps refresh disabled until the url looks like youtube', () => {
    renderFields({ youtube_url: '' });
    expect(screen.getByRole('button', { name: /refresh resolution/i })).toBeDisabled();

    fireEvent.change(screen.getByPlaceholderText(/youtube.com/), {
      target: { value: 'https://www.youtube.com/watch?v=fixture' },
    });
    expect(screen.getByRole('button', { name: /refresh resolution/i })).not.toBeDisabled();
  });

  it('shows a loading check button while inspect is in flight', async () => {
    let resolveInspect: ((value: { data: YoutubeInspectData }) => void) | undefined;
    vi.mocked(youtubeApi.inspect).mockImplementation(
      () => new Promise((resolve) => { resolveInspect = resolve; }),
    );
    renderFields({ youtube_url: 'https://youtu.be/fixture' });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /check/i })).toHaveClass('ant-btn-loading');
    });

    resolveInspect?.({ data: { live: false, variants: [] } });
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /check/i })).not.toHaveClass('ant-btn-loading');
    });
  });

  it('populates quality options and sets the first format when none was saved', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({ data: inspectVariants });
    renderFields({ youtube_url: 'https://www.youtube.com/watch?v=fixture' });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText('Formats discovered')).toBeInTheDocument();
      expect(screen.getByText('Fixture stream')).toBeInTheDocument();
    });
    expect(form.getFieldValue('youtube_format_id')).toBe('137');
    expect(form.getFieldValue('youtube_live_mode')).toBe(true);
    expect(youtubeApi.inspect).toHaveBeenCalledWith(
      'https://www.youtube.com/watch?v=fixture',
      'best[height<=1080]',
    );

    const qualitySelect = screen.getAllByRole('combobox')[0];
    expect(qualitySelect).not.toBeDisabled();
    fireEvent.mouseDown(qualitySelect);
    fireEvent.click(await screen.findByText('audio only (m4a)'));
    expect(form.getFieldValue('youtube_format_id')).toBe('140');
  });

  it('passes a custom quality policy to inspect and refresh', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({ data: { live: false, variants: [] } });
    renderFields({
      youtube_url: 'https://youtu.be/fixture',
      youtube_quality_policy: 'bestaudio',
      youtube_format_id: '140',
    });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));
    await waitFor(() => {
      expect(youtubeApi.inspect).toHaveBeenCalledWith('https://youtu.be/fixture', 'bestaudio');
    });

    fireEvent.click(screen.getByRole('button', { name: /refresh resolution/i }));
    await waitFor(() => {
      expect(youtubeApi.refresh).toHaveBeenCalledWith({
        url: 'https://youtu.be/fixture',
        format_id: '140',
        quality_policy: 'bestaudio',
      });
    });
    await waitFor(() => {
      expect(screen.getByText(/Refresh accepted/i)).toBeInTheDocument();
    });
  });

  it('keeps a saved format when inspect discovers variants', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({ data: inspectVariants });
    renderFields({
      youtube_url: 'https://youtu.be/fixture',
      youtube_format_id: '140',
    });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText('Formats discovered')).toBeInTheDocument();
    });
    expect(form.getFieldValue('youtube_format_id')).toBe('140');
    expect(screen.getByText('140')).toBeInTheDocument();
  });

  it('shows the saved format id even when it is not among discovered variants', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({ data: inspectVariants });
    renderFields({
      youtube_url: 'https://youtu.be/fixture',
      youtube_format_id: '999',
    });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText('Formats discovered')).toBeInTheDocument();
    });
    expect(form.getFieldValue('youtube_format_id')).toBe('999');
    expect(screen.getByText(/Format:/)).toBeInTheDocument();
    expect(screen.getAllByText('999').length).toBeGreaterThan(0);
  });

  it('lets the operator clear the selected format to rely on fallback policy', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({ data: inspectVariants });
    renderFields({
      youtube_url: 'https://youtu.be/fixture',
    });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));
    await waitFor(() => expect(screen.getByText('Formats discovered')).toBeInTheDocument());
    expect(form.getFieldValue('youtube_format_id')).toBe('137');

    form.setFieldValue('youtube_format_id', undefined);
    expect(form.getFieldValue('youtube_format_id')).toBeUndefined();
    const qualitySelect = screen.getAllByRole('combobox')[0];
    expect(qualitySelect).not.toHaveTextContent('1080p60');
  });

  it('updates the vod end action in the form', async () => {
    renderFields();

    fireEvent.mouseDown(screen.getAllByRole('combobox')[1]);
    fireEvent.click(await screen.findByText('Hold (reserved)'));

    expect(form.getFieldValue('youtube_end_action')).toBe('hold');
  });

  it('surfaces inspect failures with resolver-specific guidance', async () => {
    const error = new Error('resolver failed') as Error & { payload: unknown };
    error.payload = { error: { code: 'RESOLVER_TIMEOUT' } };
    vi.mocked(youtubeApi.inspect).mockRejectedValue(error);
    renderFields({ youtube_url: 'https://youtu.be/fixture' });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText(/timed out/i)).toBeInTheDocument();
      expect(screen.getByText(/try resolving again later/i)).toBeInTheDocument();
    });
    expect(screen.queryByText('Formats discovered')).not.toBeInTheDocument();
  });

  it('surfaces unreadable cookies configuration failures', async () => {
    const error = new Error('cookies') as Error & { payload: unknown };
    error.payload = { code: 'COOKIES_UNREADABLE' };
    vi.mocked(youtubeApi.inspect).mockRejectedValue(error);
    renderFields({ youtube_url: 'https://youtu.be/fixture' });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText(/cookies file cannot be read/i)).toBeInTheDocument();
    });
  });

  it('clears inspect results when the url changes after a successful check', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({ data: inspectVariants });
    renderFields({ youtube_url: 'https://youtu.be/fixture' });

    fireEvent.click(screen.getByRole('button', { name: /check/i }));
    await waitFor(() => expect(screen.getByText('Formats discovered')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/youtube.com/), {
      target: { value: 'https://youtu.be/other' },
    });

    await waitFor(() => {
      expect(screen.queryByText('Formats discovered')).not.toBeInTheDocument();
    });
  });

  it('shows em dashes for resolution timestamps when none are stored', () => {
    renderFields({ youtube_url: 'https://youtu.be/fixture' });
    expect(screen.getByText(/Resolution obtained: — · Next refresh due: —/)).toBeInTheDocument();
  });

  it('keeps the quality select disabled until formats are discovered', () => {
    renderFields({ youtube_url: 'https://youtu.be/fixture' });

    const qualitySelect = screen.getAllByRole('combobox')[0];
    expect(qualitySelect).toBeDisabled();
    expect(screen.getByText('Check the URL to discover formats')).toBeInTheDocument();
  });
});
