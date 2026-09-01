import {
  Alert,
  Button,
  Card,
  Col,
  Form,
  Input,
  Row,
  Select,
  Space,
  Tag,
  Typography,
  message,
} from 'antd';
import { CheckOutlined, ReloadOutlined } from '@ant-design/icons';
import { useEffect, useMemo, useState } from 'react';
import { youtubeApi } from '../../utils/api';
import { getErrorMessage } from '../../types/errors';
import type { YoutubeInspectData, YoutubeMediaInfo } from '../../types/youtube';

const { Text } = Typography;
type FieldName = string | number | Array<string | number>;
type InspectState = 'idle' | 'checking' | 'success' | 'error';

type Props = {
  /** Prefix is the Form.List path; standalone source editing uses no prefix. */
  namePrefix?: Array<string | number>;
};

const fieldName = (prefix: Props['namePrefix'], key: string): FieldName =>
  prefix && prefix.length > 0 ? [...prefix, key] : key;

const isYoutubeUrl = (value: string) => {
  try {
    const hostname = new URL(value).hostname.toLowerCase();
    return ['youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be'].includes(hostname);
  } catch {
    return false;
  }
};

const mediaString = (media: YoutubeMediaInfo | null | undefined, key: string): string | null => {
  const value = media?.[key];
  return typeof value === 'string' && value.length > 0 ? value : null;
};

const mediaNumber = (media: YoutubeMediaInfo | null | undefined, keys: string[]): number | null => {
  for (const key of keys) {
    const value = media?.[key];
    if (typeof value === 'number' && Number.isFinite(value)) return value;
  }
  return null;
};

const displayDate = (item: unknown) => {
  if (typeof item !== 'string' || item.length === 0) return '—';
  const date = new Date(item);
  return Number.isNaN(date.getTime()) ? item : date.toLocaleString();
};

const errorCode = (error: unknown): string | null => {
  if (!error || typeof error !== 'object') return null;
  const payload = (error as { payload?: unknown }).payload;
  if (!payload || typeof payload !== 'object') return null;
  const nested = (payload as { error?: unknown }).error;
  if (nested && typeof nested === 'object' && typeof (nested as { code?: unknown }).code === 'string') {
    return (nested as { code: string }).code;
  }
  return typeof (payload as { code?: unknown }).code === 'string'
    ? (payload as { code: string }).code
    : null;
};

const errorMessage = (error: unknown): { message: string; code: string | null } => {
  const code = errorCode(error);
  if (code === 'BOT_CHECK_CHALLENGE') {
    return {
      code,
      message: 'YouTube requested a bot check. Configure YOUTUBE_COOKIES_PATH with a valid browser cookies file, then try again.',
    };
  }
  if (code === 'COOKIES_UNREADABLE') {
    return { code, message: 'The configured YouTube cookies file cannot be read. Check YOUTUBE_COOKIES_PATH and its permissions.' };
  }
  const labels: Record<string, string> = {
    INVALID_URL: 'Enter a valid YouTube watch URL.',
    UNSUPPORTED_FORMAT: 'No supported audio/video format was found for this video.',
    RESOLVER_NOT_FOUND: 'The yt-dlp resolver executable was not found.',
    RESOLVER_TIMEOUT: 'YouTube inspection timed out. Try again or check the resolver host.',
    INVALID_OUTPUT: 'The resolver returned an invalid response.',
    RESOLVER_FAILED: 'YouTube inspection failed.',
  };
  return { code, message: labels[code || ''] || getErrorMessage(error, 'YouTube inspection failed.') };
};

const YoutubeInputFields = ({ namePrefix }: Props) => {
  const form = Form.useFormInstance();
  const [messageApi, contextHolder] = message.useMessage();
  const url = Form.useWatch(fieldName(namePrefix, 'youtube_url'), form) as string | undefined;
  const policy = Form.useWatch(fieldName(namePrefix, 'youtube_quality_policy'), form) as string | undefined;
  const savedMedia = Form.useWatch(fieldName(namePrefix, 'youtube_media_info'), form) as YoutubeMediaInfo | null | undefined;
  const savedLive = Form.useWatch(fieldName(namePrefix, 'youtube_live_mode'), form) as boolean | null | undefined;
  const savedFormat = Form.useWatch(fieldName(namePrefix, 'youtube_format_id'), form) as string | null | undefined;
  const infoUpdatedAt = Form.useWatch(fieldName(namePrefix, 'youtube_info_updated_at'), form) as string | null | undefined;
  const nextRefreshAt = Form.useWatch(fieldName(namePrefix, 'youtube_next_refresh_at'), form) as string | null | undefined;
  const [state, setState] = useState<InspectState>('idle');
  const [inspectData, setInspectData] = useState<YoutubeInspectData | null>(null);
  const [checkedUrl, setCheckedUrl] = useState<string | null>(null);
  const [failureMessage, setFailureMessage] = useState<string | null>(null);

  useEffect(() => {
    const normalizedUrl = (url || '').trim();
    if (checkedUrl !== normalizedUrl) {
      setState('idle');
      setInspectData(null);
      setFailureMessage(null);
    }
  }, [checkedUrl, url]);

  const media = inspectData?.media_info || savedMedia;
  const variants = useMemo(() => inspectData?.variants || [], [inspectData]);
  const live = inspectData?.live ?? savedLive;
  const selectedFormat = inspectData?.variants.some((variant) => variant.format_id === savedFormat)
    ? savedFormat
    : undefined;
  const selectedVariant = variants.find((variant) => variant.format_id === (selectedFormat || savedFormat)) || variants[0];

  const formatOptions = useMemo(() => variants.map((variant) => ({
    value: variant.format_id,
    label: variant.label,
  })), [variants]);

  const check = async () => {
    const normalizedUrl = (url || '').trim();
    if (!isYoutubeUrl(normalizedUrl)) {
      setState('error');
      setInspectData(null);
      setCheckedUrl(normalizedUrl);
      setFailureMessage('Enter a valid YouTube watch URL.');
      return;
    }

    setState('checking');
    setCheckedUrl(normalizedUrl);
    try {
      const response = await youtubeApi.inspect(normalizedUrl, policy?.trim() || undefined);
      const data = response.data;
      setInspectData(data);
      setState('success');
      setFailureMessage(null);
      if (data.variants.length > 0 && !savedFormat) {
        form.setFieldValue(fieldName(namePrefix, 'youtube_format_id'), data.variants[0].format_id);
      }
      if (data.media_info) {
        form.setFieldValue(fieldName(namePrefix, 'youtube_media_info'), data.media_info);
      }
      form.setFieldValue(fieldName(namePrefix, 'youtube_live_mode'), data.live);
    } catch (error) {
      setState('error');
      setInspectData(null);
      const failure = errorMessage(error);
      setFailureMessage(failure.message);
      if (failure.code === 'BOT_CHECK_CHALLENGE') messageApi.error(failure.message);
    }
  };

  const refresh = async () => {
    const normalizedUrl = (url || '').trim();
    if (!isYoutubeUrl(normalizedUrl)) return;
    try {
      await youtubeApi.refresh({
        url: normalizedUrl,
        format_id: savedFormat || null,
        quality_policy: policy?.trim() || null,
      });
      messageApi.success('Refresh accepted. The source will restart and downstream receivers will reconnect.');
    } catch (error) {
      const failure = errorMessage(error);
      messageApi.error(failure.message);
    }
  };

  return (
    <Card size="small" title="YouTube source" variant="outlined">
      {contextHolder}
      <Form.Item
        label="YouTube watch URL"
        name={fieldName(namePrefix, 'youtube_url')}
        rules={[{ required: true, message: 'Please enter a YouTube watch URL' }]}
        extra="Only the watch URL is stored. The resolved media URL is temporary and never shown."
      >
        <Input placeholder="https://www.youtube.com/watch?v=..." />
      </Form.Item>
      <Form.Item
        label="Quality fallback policy"
        name={fieldName(namePrefix, 'youtube_quality_policy')}
        initialValue="best[height<=1080]"
        extra="Left empty it falls back to best[height<=1080]. Used at route start when the event is not live yet or the selected format is unavailable."
      >
        <Input placeholder="best[height<=1080]" />
      </Form.Item>
      <Form.Item label="Selected quality" name={fieldName(namePrefix, 'youtube_format_id')}>
        <Select
          allowClear
          disabled={formatOptions.length === 0}
          options={formatOptions}
          placeholder={formatOptions.length === 0 ? 'Check the URL to discover formats' : 'Use fallback policy'}
        />
      </Form.Item>
      <Form.Item label="VOD end action" name={fieldName(namePrefix, 'youtube_end_action')} initialValue="stop">
        <Select options={[{ value: 'stop', label: 'Stop when playback completes' }, { value: 'hold', label: 'Hold (reserved)' }, { value: 'loop', label: 'Loop (reserved)' }]} />
      </Form.Item>
      <Space wrap>
        <Button icon={<CheckOutlined />} loading={state === 'checking'} onClick={() => void check()}>
          Check
        </Button>
        <Button icon={<ReloadOutlined />} disabled={!isYoutubeUrl((url || '').trim())} onClick={() => void refresh()}>
          Refresh resolution
        </Button>
      </Space>
      <Text type="secondary" style={{ display: 'block', marginTop: 8 }}>
        Refreshing restarts the source; downstream receivers will reconnect briefly. This is expected.
      </Text>
      <Text type="secondary" style={{ display: 'block', marginTop: 8 }}>
        Resolution obtained: {displayDate(infoUpdatedAt)} · Next refresh due: {displayDate(nextRefreshAt)}
      </Text>
      {state === 'error' && failureMessage && (
        <Alert
          type="error"
          showIcon
          style={{ marginTop: 12 }}
          message={failureMessage}
          description={failureMessage.includes('bot check') ? undefined : 'You can save the fallback policy and try resolving again later.'}
        />
      )}
      {state === 'success' && (
        <Alert
          type="success"
          showIcon
          style={{ marginTop: 12 }}
          message={variants.length > 0 ? 'Formats discovered' : 'URL checked; no formats are available yet'}
          description={variants.length === 0 ? 'This event may not be live yet. You can save the fallback policy and resolve it when the route starts.' : undefined}
        />
      )}
      {(state === 'success' || savedMedia) && (
        <Card size="small" title="Announced stream metadata" style={{ marginTop: 12 }}>
          <Row gutter={[12, 8]}>
            <Col xs={24} sm={12}><Text strong>Title: </Text>{mediaString(media, 'title') || '—'}</Col>
            <Col xs={24} sm={12}><Text strong>Status: </Text>{live == null ? '—' : live ? <Tag color="green">Live</Tag> : <Tag>VOD</Tag>}</Col>
            <Col xs={24} sm={12}><Text strong>Format: </Text>{selectedFormat || savedFormat || mediaString(media, 'format_id') || selectedVariant?.label || 'Fallback policy'}</Col>
            <Col xs={24} sm={12}><Text strong>Bitrate: </Text>{mediaNumber(media, ['bitrate', 'tbr']) != null ? `${mediaNumber(media, ['bitrate', 'tbr'])} kbps` : '—'}</Col>
            <Col xs={24} sm={12}><Text strong>Video: </Text>{mediaString(media?.video as YoutubeMediaInfo | null, 'codec') || (selectedVariant?.has_video ? 'Announced' : '—')}</Col>
            <Col xs={24} sm={12}><Text strong>Audio: </Text>{mediaString(media?.audio as YoutubeMediaInfo | null, 'codec') || (selectedVariant?.has_audio ? 'Announced' : '—')}</Col>
            <Col xs={24} sm={12}><Text strong>Resolution: </Text>{media?.video && typeof media.video.width === 'number' && typeof media.video.height === 'number' ? `${media.video.width}×${media.video.height}` : selectedVariant?.width && selectedVariant.height ? `${selectedVariant.width}×${selectedVariant.height}` : '—'}</Col>
            <Col xs={24} sm={12}><Text strong>FPS: </Text>{media?.video && typeof media.video.fps === 'number' ? media.video.fps : selectedVariant?.fps ?? '—'}</Col>
            {selectedVariant?.label && <Col xs={24}><Text type="secondary">Announced format details: {selectedVariant.label}</Text></Col>}
          </Row>
        </Card>
      )}
    </Card>
  );
};

export default YoutubeInputFields;
