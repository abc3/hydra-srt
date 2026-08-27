import {
  Alert,
  Badge,
  Button,
  Card,
  Col,
  Empty,
  Row,
  Space,
  Statistic,
  Tag,
  Typography,
} from 'antd';
import { ReloadOutlined } from '@ant-design/icons';
import { useCallback, useEffect, useMemo, useState } from 'react';
import type { RouteEndpoint } from '../../types/routes';
import type { YoutubeMediaInfo } from '../../types/youtube';
import { getErrorMessage } from '../../types/errors';
import { routesApi } from '../../utils/api';
import { subscribeToEndpointHealth } from '../../utils/realtime';

const { Text, Title } = Typography;
type HealthRecord = Record<string, unknown> & { endpoint_id?: string; state?: string; sequence?: number };
type Props = { routeId: string; sources: RouteEndpoint[]; routeActive?: boolean };

const isYoutube = (endpoint: RouteEndpoint) => String(endpoint.schema || '').toUpperCase() === 'YOUTUBE';
const value = (object: Record<string, unknown> | null | undefined, keys: string[]): unknown => {
  for (const key of keys) if (object?.[key] !== undefined && object[key] !== null) return object[key];
  return null;
};
const stringValue = (object: Record<string, unknown> | null | undefined, keys: string[]) => {
  const item = value(object, keys);
  return typeof item === 'string' && item.length > 0 ? item : '—';
};
const displayValue = (object: Record<string, unknown> | null | undefined, keys: string[]) => {
  const item = value(object, keys);
  if (typeof item === 'string' || typeof item === 'number') return String(item);
  if (item && typeof item === 'object') return JSON.stringify(item);
  return '—';
};
const numberValue = (object: Record<string, unknown> | null | undefined, keys: string[]) => {
  const item = value(object, keys);
  return typeof item === 'number' && Number.isFinite(item) ? item : null;
};
const mediaValue = (endpoint: RouteEndpoint): YoutubeMediaInfo | null => {
  const media = endpoint.youtube_media_info;
  return media && typeof media === 'object' ? media : null;
};
const displayDate = (item: unknown) => {
  if (typeof item !== 'string' || !item) return '—';
  const date = new Date(item);
  return Number.isNaN(date.getTime()) ? item : date.toLocaleString();
};

const YoutubeHealthTab = ({ routeId, sources, routeActive = true }: Props) => {
  const youtubeSources = useMemo(() => sources.filter(isYoutube), [sources]);
  const [healthById, setHealthById] = useState<Record<string, HealthRecord>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const applySnapshot = useCallback((snapshot: Record<string, unknown>) => {
    const records = Array.isArray(snapshot.endpoints)
      ? snapshot.endpoints
      : snapshot.endpoint_health && typeof snapshot.endpoint_health === 'object'
        ? Object.values(snapshot.endpoint_health)
        : [];
    const next: Record<string, HealthRecord> = {};
    records.forEach((record) => {
      if (record && typeof record === 'object' && typeof (record as HealthRecord).endpoint_id === 'string') {
        const typed = record as HealthRecord;
        next[typed.endpoint_id as string] = typed;
      }
    });
    setHealthById(next);
  }, []);

  const fetchSnapshot = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await routesApi.getEndpointHealth(routeId) as { data?: Record<string, unknown> };
      if (response.data) applySnapshot(response.data);
    } catch (err) {
      setError(getErrorMessage(err, 'Failed to load YouTube pipeline health'));
    } finally {
      setLoading(false);
    }
  }, [applySnapshot, routeId]);

  useEffect(() => {
    const unsubscribe = subscribeToEndpointHealth(routeId, (payload) => {
      const record = payload as HealthRecord;
      if (record.endpoint_id && youtubeSources.some((source) => source.id === record.endpoint_id)) {
        setHealthById((current) => ({ ...current, [record.endpoint_id as string]: record }));
      }
    });
    void fetchSnapshot();
    return unsubscribe;
  }, [fetchSnapshot, routeId, youtubeSources]);

  if (youtubeSources.length === 0) return <Empty description="This route has no YouTube sources" />;

  return (
    <Space direction="vertical" size="middle" style={{ width: '100%' }}>
      {error && <Alert type="error" showIcon message={error} action={<Button onClick={() => void fetchSnapshot()}>Retry</Button>} />}
      {!routeActive && <Alert type="info" showIcon message="Route is stopped" description="Showing persisted YouTube metadata and the last known pipeline health." />}
      {youtubeSources.map((endpoint) => {
        const endpointId = endpoint.id ? String(endpoint.id) : '';
        const health = healthById[endpointId];
        const liveMedia = health?.youtube_media_info;
        const media = liveMedia && typeof liveMedia === 'object' ? liveMedia as YoutubeMediaInfo : mediaValue(endpoint);
        const announcedVideo = media?.video && typeof media.video === 'object' ? media.video : null;
        const announcedAudio = media?.audio && typeof media.audio === 'object' ? media.audio : null;
        const persistedActual = value(media, ['actual', 'pipeline', 'pipeline_health']);
        const actualMediaInfo = value(health, ['media_info']);
        const actual = health?.actual && typeof health.actual === 'object'
          ? health.actual as Record<string, unknown>
          : persistedActual && typeof persistedActual === 'object'
            ? persistedActual as Record<string, unknown>
            : actualMediaInfo && typeof actualMediaInfo === 'object'
              ? actualMediaInfo as Record<string, unknown>
            : health;
        const state = typeof health?.state === 'string' ? health.state : routeActive ? 'unknown' : 'stopped';
        const status = state === 'streaming' ? 'success' : state === 'reconnecting' ? 'processing' : 'default';
        const title = typeof media?.title === 'string' ? media.title : endpoint.name || endpoint.youtube_url || 'YouTube source';

        return (
          <Card key={endpointId || title} loading={loading && !health} title={<Space><Badge status={status} text={state} /><Title level={5} style={{ margin: 0 }}>{title}</Title></Space>}>
            <Row gutter={[16, 16]}>
              <Col xs={24} lg={12}>
                <Card size="small" title="Announced by YouTube">
                  <Space direction="vertical" style={{ width: '100%' }}>
                    <Text><b>Live status:</b> {(health?.youtube_live_mode ?? endpoint.youtube_live_mode) == null ? '—' : (health?.youtube_live_mode ?? endpoint.youtube_live_mode) ? 'Live' : 'VOD'}</Text>
                    <Text><b>Selected quality:</b> {endpoint.youtube_format_id || 'Fallback policy'}</Text>
                    <Text><b>Format ID:</b> {endpoint.youtube_format_id || media?.format_id || '—'}</Text>
                    <Text><b>Video codec:</b> {stringValue(announcedVideo, ['codec']) !== '—' ? stringValue(announcedVideo, ['codec']) : stringValue(media, ['video_codec'])}</Text>
                    <Text><b>Audio codec:</b> {stringValue(announcedAudio, ['codec']) !== '—' ? stringValue(announcedAudio, ['codec']) : stringValue(media, ['audio_codec'])}</Text>
                    <Text><b>Resolution:</b> {numberValue(announcedVideo, ['width', 'video_width']) != null && numberValue(announcedVideo, ['height', 'video_height']) != null ? `${numberValue(announcedVideo, ['width', 'video_width'])}×${numberValue(announcedVideo, ['height', 'video_height'])}` : '—'}</Text>
                    <Text><b>FPS:</b> {numberValue(announcedVideo, ['fps', 'frame_rate']) ?? numberValue(media, ['fps']) ?? '—'}</Text>
                    <Text><b>Bitrate:</b> {numberValue(media, ['bitrate', 'tbr', 'bitrate_kbps']) != null ? `${numberValue(media, ['bitrate', 'tbr', 'bitrate_kbps'])} kbps` : '—'}</Text>
                    <Text type="secondary">Observed {displayDate(health?.youtube_info_updated_at || endpoint.youtube_info_updated_at)}</Text>
                  </Space>
                </Card>
              </Col>
              <Col xs={24} lg={12}>
                <Card size="small" title="Actual from the pipeline">
                  <Row gutter={[8, 8]}>
                    <Col span={12}><Statistic title="Caps" value={displayValue(actual, ['caps', 'video_caps', 'video'])} /></Col>
                    <Col span={12}><Statistic title="Current bitrate" value={numberValue(actual, ['current_bitrate_kbps', 'bitrate_kbps', 'bitrate', 'bitrate_bps']) ?? '—'} suffix={numberValue(actual, ['current_bitrate_kbps', 'bitrate_kbps', 'bitrate']) != null ? 'kbps' : undefined} /></Col>
                    <Col span={12}><Statistic title="Discontinuities" value={numberValue(actual, ['discontinuity_count', 'discontinuities']) ?? '—'} /></Col>
                    <Col span={12}><Statistic title="Segment stalls" value={numberValue(actual, ['segment_stalls', 'segment_stall_count', 'stall_count']) ?? '—'} /></Col>
                  </Row>
                  <Space direction="vertical" style={{ width: '100%', marginTop: 12 }}>
                    <Text><b>Last refresh:</b> {displayDate(value(actual, ['last_refresh_at', 'last_refresh_time']) || value(endpoint, ['youtube_last_refresh_at']))}</Text>
                    <Text><b>Next scheduled refresh:</b> {displayDate(value(actual, ['next_refresh_at', 'next_scheduled_refresh']) || value(endpoint, ['youtube_next_refresh_at']))}</Text>
                    <Text><b>Pipeline state:</b> <Tag color={state === 'streaming' ? 'green' : undefined}>{state}</Tag></Text>
                  </Space>
                </Card>
              </Col>
            </Row>
          </Card>
        );
      })}
      <Button icon={<ReloadOutlined />} onClick={() => void fetchSnapshot()}>Refresh health</Button>
    </Space>
  );
};

export default YoutubeHealthTab;
