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
import {
  ExperimentOutlined,
  ReloadOutlined,
  StopOutlined,
  WarningOutlined,
} from '@ant-design/icons';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { NdiEndpointHealthRecord, NdiEndpointHealthSnapshot } from '../../types/ndi';
import type { RouteEndpoint } from '../../types/routes';
import { getErrorMessage } from '../../types/errors';
import { ndiApi } from '../../utils/ndiApi';
import { subscribeToEndpointHealth } from '../../utils/realtime';
import { routesApi } from '../../utils/api';
import { reasonCodeExplanation } from './ndiCapabilityState';

const { Text, Title } = Typography;

type Props = {
  routeId: string;
  sources: RouteEndpoint[];
  destinations: RouteEndpoint[];
  activeSourceId?: string;
  routeActive?: boolean;
  onRestartWithSource?: (sourceId: string) => void;
  onStop?: () => void;
  onTestEndpoint?: (endpointId: string) => void;
};

const isNdi = (endpoint: RouteEndpoint) =>
  String(endpoint.schema || '').toUpperCase() === 'NDI';

const stateLabel = (state?: string | null) => {
  if (!state) return 'Unknown';
  return state
    .split(/[_\s-]+/)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
};

const stateBadge = (state?: string | null): 'success' | 'processing' | 'warning' | 'error' | 'default' => {
  switch ((state || '').toLowerCase()) {
    case 'streaming':
    case 'advertising':
      return 'success';
    case 'connecting':
    case 'negotiating':
    case 'discovering':
    case 'validating':
    case 'probing':
    case 'reconnecting':
      return 'processing';
    case 'degraded':
    case 'standby':
      return 'warning';
    case 'unavailable':
    case 'configuration_error':
      return 'error';
    case 'stopped':
    case 'disabled':
    default:
      return 'default';
  }
};

const MAX_BUFFER = 200;

type Cursor = {
  config_revision: string | null;
  process_instance_id: string | null;
  last_sequence: number;
};

const NdiHealthTab = ({
  routeId,
  sources,
  destinations,
  activeSourceId,
  routeActive = true,
  onRestartWithSource,
  onStop,
  onTestEndpoint,
}: Props) => {
  const ndiSources = useMemo(() => sources.filter(isNdi), [sources]);
  const ndiDestinations = useMemo(() => destinations.filter(isNdi), [destinations]);
  const [healthById, setHealthById] = useState<Record<string, NdiEndpointHealthRecord>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [announce, setAnnounce] = useState('');
  const cursorRef = useRef<Cursor>({
    config_revision: null,
    process_instance_id: null,
    last_sequence: 0,
  });
  const bufferRef = useRef<NdiEndpointHealthRecord[]>([]);
  const liveRef = useRef(false);
  const prevCriticalRef = useRef<Record<string, string>>({});

  const applyRecord = useCallback((record: NdiEndpointHealthRecord) => {
    if (!record.endpoint_id) {
      return;
    }
    setHealthById((prev) => ({ ...prev, [record.endpoint_id]: record }));

    const state = (record.state || '').toLowerCase();
    const critical = state === 'unavailable' || state === 'configuration_error';
    const previous = prevCriticalRef.current[record.endpoint_id];
    if (critical && previous !== state) {
      setAnnounce(`Critical NDI media loss on endpoint ${record.endpoint_id}: ${stateLabel(record.state)}`);
    }
    prevCriticalRef.current[record.endpoint_id] = state;
  }, []);

  const applySnapshot = useCallback((snapshot: NdiEndpointHealthSnapshot) => {
    const next: Record<string, NdiEndpointHealthRecord> = {};
    for (const record of snapshot.endpoints || []) {
      if (record.endpoint_id) {
        next[record.endpoint_id] = record;
      }
    }
    setHealthById(next);
    cursorRef.current = {
      config_revision: snapshot.config_revision,
      process_instance_id: snapshot.process_instance_id,
      last_sequence: snapshot.last_sequence || 0,
    };
  }, []);

  const fetchSnapshot = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await ndiApi.getEndpointHealth(routeId);
      const snapshot = response.data;
      if (!snapshot) {
        throw new Error('Empty endpoint-health snapshot');
      }
      applySnapshot(snapshot);

      const cursor = cursorRef.current;
      const buffered = bufferRef.current;
      bufferRef.current = [];
      const newer = buffered
        .filter((event) => {
          if (
            event.config_revision !== cursor.config_revision ||
            event.process_instance_id !== cursor.process_instance_id
          ) {
            return false;
          }
          return (event.sequence ?? 0) > cursor.last_sequence;
        })
        .sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0));

      newer.forEach((event) => {
        applyRecord(event);
        cursorRef.current.last_sequence = Math.max(
          cursorRef.current.last_sequence,
          event.sequence ?? 0,
        );
      });
      liveRef.current = true;
    } catch (err) {
      setError(getErrorMessage(err, 'Failed to load NDI endpoint health'));
      liveRef.current = false;
    } finally {
      setLoading(false);
    }
  }, [applyRecord, applySnapshot, routeId]);

  useEffect(() => {
    liveRef.current = false;
    bufferRef.current = [];

    const unsubscribe = subscribeToEndpointHealth(routeId, (payload) => {
      const event = payload as NdiEndpointHealthRecord;
      if (!event || typeof event !== 'object') {
        return;
      }

      if (!liveRef.current) {
        bufferRef.current.push(event);
        if (bufferRef.current.length > MAX_BUFFER) {
          bufferRef.current = [];
          void fetchSnapshot();
        }
        return;
      }

      const cursor = cursorRef.current;
      if (
        event.config_revision !== cursor.config_revision ||
        event.process_instance_id !== cursor.process_instance_id
      ) {
        liveRef.current = false;
        bufferRef.current = [event];
        void fetchSnapshot();
        return;
      }

      const sequence = event.sequence ?? 0;
      if (sequence <= cursor.last_sequence) {
        return;
      }
      if (sequence > cursor.last_sequence + 1) {
        liveRef.current = false;
        bufferRef.current = [event];
        void fetchSnapshot();
        return;
      }

      applyRecord(event);
      cursorRef.current.last_sequence = sequence;
    });

    void fetchSnapshot();

    return () => {
      unsubscribe();
      liveRef.current = false;
    };
  }, [applyRecord, fetchSnapshot, routeId]);

  const cards = useMemo(() => {
    const sourceCards = ndiSources.map((endpoint) => ({
      endpoint,
      direction: 'source' as const,
      role:
        endpoint.id === activeSourceId
          ? 'active'
          : endpoint.enabled === false
            ? 'disabled'
            : 'standby',
    }));
    const destCards = ndiDestinations.map((endpoint) => ({
      endpoint,
      direction: 'destination' as const,
      role: endpoint.enabled === false ? 'disabled' : 'output',
    }));
    return [...sourceCards, ...destCards];
  }, [activeSourceId, ndiDestinations, ndiSources]);

  if (cards.length === 0) {
    return <Empty description="This route has no NDI endpoints" />;
  }

  return (
    <Space direction="vertical" size="middle" style={{ width: '100%' }}>
      <div aria-live="assertive" aria-atomic="true" style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden' }}>
        {announce}
      </div>

      {error && <Alert type="error" showIcon message={error} action={<Button onClick={() => void fetchSnapshot()}>Retry</Button>} />}
      {!routeActive && (
        <Alert type="info" showIcon message="Route is stopped" description="Showing last known NDI health; live samples pause while stopped." />
      )}

      <Row gutter={[16, 16]}>
        {cards.map(({ endpoint, direction, role }) => {
          const health = endpoint.id ? healthById[endpoint.id] : undefined;
          const savedIdentity =
            direction === 'source'
              ? endpoint.ndi_source_name || endpoint.ndi_source_address || endpoint.name
              : endpoint.ndi_sender_name || endpoint.name;
          const state =
            role === 'disabled'
              ? 'disabled'
              : role === 'standby' && !['streaming', 'connecting', 'reconnecting'].includes((health?.state || '').toLowerCase())
                ? health?.state || 'standby'
                : health?.state || (routeActive ? 'unknown' : 'stopped');
          const currentIdentity = health?.current_name || health?.current_address;
          const identityMismatch =
            Boolean(currentIdentity) &&
            Boolean(savedIdentity) &&
            String(currentIdentity) !== String(savedIdentity);

          return (
            <Col xs={24} lg={12} key={`${direction}-${endpoint.id}`}>
              <Card
                size="small"
                loading={loading && !health}
                title={
                  <Space wrap>
                    <Badge status={stateBadge(state)} text={stateLabel(state)} />
                    <Tag>{direction}</Tag>
                    {role === 'active' && <Tag color="green">Active source</Tag>}
                    {role === 'standby' && <Tag>Standby</Tag>}
                  </Space>
                }
              >
                <Space direction="vertical" size="small" style={{ width: '100%' }}>
                  <Title level={5} style={{ margin: 0 }}>
                    {String(savedIdentity || endpoint.name || endpoint.id || 'NDI endpoint')}
                  </Title>
                  {health?.reason_code && (
                    <Text>
                      <WarningOutlined aria-hidden /> {health.reason_code}:{' '}
                      {health.detail || reasonCodeExplanation(health.reason_code)}
                    </Text>
                  )}
                  {identityMismatch && (
                    <Alert
                      type="warning"
                      showIcon
                      message="Current versus saved identity"
                      description={`Saved: ${savedIdentity} · Current: ${currentIdentity}`}
                    />
                  )}
                  <Row gutter={12}>
                    <Col span={8}>
                      <Statistic title="Frame age (v)" value={health?.last_video_buffer_age_ms ?? '—'} suffix={health?.last_video_buffer_age_ms != null ? 'ms' : undefined} />
                    </Col>
                    <Col span={8}>
                      <Statistic title="A/V skew" value={health?.skew_ms ?? '—'} suffix={health?.skew_ms != null ? 'ms' : undefined} />
                    </Col>
                    <Col span={8}>
                      <Statistic title="Drops" value={health?.drops ?? '—'} />
                    </Col>
                  </Row>
                  <Row gutter={12}>
                    <Col span={8}>
                      <Statistic title="Queue" value={health?.queue_level ?? '—'} />
                    </Col>
                    <Col span={8}>
                      <Statistic title="Reconnects" value={health?.reconnect_attempts ?? health?.attempt ?? '—'} />
                    </Col>
                    <Col span={8}>
                      <Statistic
                        title="Receivers"
                        value={health?.receiver_count != null ? health.receiver_count : '—'}
                      />
                    </Col>
                  </Row>
                  {health && Boolean(health.video_caps || health.audio_caps) && (
                    <Text type="secondary" style={{ display: 'block' }}>
                      Caps: {health.video_caps ? `video ${JSON.stringify(health.video_caps)}` : 'no video'}
                      {' · '}
                      {health.audio_caps ? `audio ${JSON.stringify(health.audio_caps)}` : 'no audio'}
                    </Text>
                  )}
                  <Space wrap>
                    {endpoint.id && onTestEndpoint && (
                      <Button
                        icon={<ExperimentOutlined />}
                        onClick={() => onTestEndpoint(endpoint.id as string)}
                       
                      >
                        Test
                      </Button>
                    )}
                    {direction === 'source' && endpoint.id && onRestartWithSource && (
                      <Button
                        icon={<ReloadOutlined />}
                        onClick={() => onRestartWithSource(endpoint.id as string)}
                       
                      >
                        Restart with source
                      </Button>
                    )}
                    {onStop && (
                      <Button icon={<StopOutlined />} onClick={onStop}>
                        Stop
                      </Button>
                    )}
                    <Button
                      type="link"
                      onClick={() => void routesApi.getById(routeId)}
                     
                    >
                      View redacted diagnostics
                    </Button>
                  </Space>
                </Space>
              </Card>
            </Col>
          );
        })}
      </Row>
    </Space>
  );
};

export default NdiHealthTab;
