import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { JSX, ReactNode } from 'react';
import {
  Alert,
  Badge,
  Button,
  Card,
  Col,
  Empty,
  Progress,
  Row,
  Space,
  Spin,
  Table,
  Tag,
  Typography,
} from 'antd';
import type { ColumnsType } from 'antd/es/table';
import {
  ApiOutlined,
  CheckCircleOutlined,
  CloudServerOutlined,
  FieldTimeOutlined,
  ForkOutlined,
  LineChartOutlined,
  ReloadOutlined,
  WarningOutlined,
} from '@ant-design/icons';
import {
  Area,
  AreaChart,
  CartesianGrid,
  Cell,
  Line,
  LineChart,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip as RechartsTooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { useInit } from '../context/InitContext';
import { dashboardApi } from '../utils/api';

const { Text, Title } = Typography;

type StatusKey = 'processing' | 'starting' | 'reconnecting' | 'restarting' | 'failed' | 'stopped' | 'other';

type DashboardEvent = {
  ts?: string | null;
  event_type?: string | null;
  severity?: string | null;
  reason?: string | null;
  message?: string | null;
};

type AttentionRow = {
  id: string;
  name: string;
  status: StatusKey;
  source_protocols: string[];
  destination_protocols: string[];
  signal: string;
  last_event?: DashboardEvent | null;
};

type DashboardData = {
  generated_at: string;
  analytics_available: boolean;
  system: {
    host?: string | null;
    cpu_percent?: number | null;
    cpu_count?: number | null;
    memory_percent?: number | null;
    memory_total_bytes?: number | null;
    swap_percent?: number | null;
    network_in_bytes_per_sec?: number | null;
    network_out_bytes_per_sec?: number | null;
    storage?: {
      mountpoint?: string;
      total_bytes?: number;
      used_bytes?: number;
      free_bytes?: number;
      used_percent?: number;
    } | null;
  };
  routes: {
    total: number;
    statuses: Partial<Record<StatusKey, number>>;
    source_protocols: Record<string, number>;
    destination_protocols: Record<string, number>;
  };
  failover: {
    on_backup: number;
    backup_unavailable: number;
    last_failover_at?: string | null;
    failbacks_today: number;
  };
  logs: {
    errors: number;
    warnings: number;
    info: number;
    last_error_at?: string | null;
    last_error_message?: string | null;
  };
  network_series: Array<{ timestamp: string; input: number; output: number }>;
  status_series: Array<Record<StatusKey | 'timestamp', number | string>>;
  attention: AttentionRow[];
};

const cardStyle = { height: '100%', border: '1px solid #303030' };
const chartGridStyle = { stroke: '#3a3a3a', strokeWidth: 0.6, strokeDasharray: '2 4' };

const statusOrder: StatusKey[] = ['processing', 'starting', 'reconnecting', 'restarting', 'failed', 'stopped', 'other'];
const statusMeta: Record<StatusKey, { label: string; color: string }> = {
  processing: { label: 'Processing', color: '#52c41a' },
  starting: { label: 'Starting', color: '#1677ff' },
  reconnecting: { label: 'Reconnecting', color: '#fa8c16' },
  restarting: { label: 'Restarting', color: '#faad14' },
  failed: { label: 'Failed', color: '#ff4d4f' },
  stopped: { label: 'Stopped', color: '#8c8c8c' },
  other: { label: 'Other', color: '#722ed1' },
};

const protocolColors: Record<string, string> = {
  SRT: '#1677ff',
  UDP: '#13c2c2',
  RTP: '#faad14',
  RTMP: '#eb2f96',
};

const AUTO_REFRESH_SECONDS = 5;

const formatBytes = (value: number | null | undefined): string => {
  if (value == null || Number.isNaN(value)) return 'N/A';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let normalized = Math.max(0, value);
  let unitIndex = 0;
  while (normalized >= 1000 && unitIndex < units.length - 1) {
    normalized /= 1000;
    unitIndex += 1;
  }
  const precision = normalized >= 100 ? 0 : normalized >= 10 ? 1 : 2;
  return `${normalized.toFixed(precision)} ${units[unitIndex]}`;
};

const formatBitrate = (bytesPerSecond: number | null | undefined): string => {
  if (bytesPerSecond == null || Number.isNaN(bytesPerSecond)) return 'N/A';
  const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  let value = Math.max(0, bytesPerSecond * 8);
  let unitIndex = 0;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }
  const precision = value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(precision)} ${units[unitIndex]}`;
};

const formatTime = (value: string | null | undefined): string => {
  if (!value) return 'No data';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'No data';
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
};

const formatRelativeTime = (value: string | null | undefined): string => {
  if (!value) return 'none recorded';
  const elapsed = Date.now() - new Date(value).getTime();
  if (!Number.isFinite(elapsed) || elapsed < 0) return formatTime(value);
  const minutes = Math.floor(elapsed / 60_000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
};

const formatUptime = (startedAt: string | null): string => {
  if (!startedAt) return 'N/A';
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000));
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3600);
  if (days > 0) return `${days}d ${hours}h`;
  const minutes = Math.floor((seconds % 3600) / 60);
  return `${hours}h ${minutes}m`;
};

const SummaryCard = ({
  icon,
  title,
  value,
  color,
  children,
}: {
  icon: JSX.Element;
  title: string;
  value: string;
  color: string;
  children: ReactNode;
}): JSX.Element => (
  <Card
    title={<Space size={10}><span style={{ color, fontSize: 20 }}>{icon}</span><Text strong>{title}</Text></Space>}
    style={cardStyle}
  >
    <Space direction="vertical" size={12} style={{ width: '100%' }}>
      <Title level={3} style={{ margin: 0 }}>{value}</Title>
      {children}
    </Space>
  </Card>
);

const SummaryLine = ({ label, value, danger }: { label: string; value: string; danger?: boolean }): JSX.Element => (
  <Space style={{ justifyContent: 'space-between', width: '100%' }}>
    <Text type="secondary">{label}</Text>
    <Text strong type={danger ? 'danger' : undefined}>{value}</Text>
  </Space>
);

const ResourceLine = ({ label, percent, color }: { label: string; percent?: number | null; color: string }): JSX.Element => (
  <div style={{ alignItems: 'center', display: 'flex', gap: 10, width: '100%' }}>
    <Text type="secondary" style={{ width: 42 }}>{label}</Text>
    <div style={{ flex: '1 1 auto', minWidth: 0 }}>
      <Progress
        percent={percent == null ? 0 : Math.round(percent)}
        showInfo={false}
        strokeColor={percent == null ? '#595959' : color}
        trailColor="#303030"
        style={{ display: 'block', width: '100%' }}
      />
    </div>
    <Text style={{ width: 42, textAlign: 'right' }}>{percent == null ? 'N/A' : `${Math.round(percent)}%`}</Text>
  </div>
);

const ProtocolDonut = ({ title, data }: { title: string; data: Array<{ name: string; value: number; color: string }> }): JSX.Element => {
  const total = data.reduce((sum, item) => sum + item.value, 0);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 18, minWidth: 0, width: '100%', flexWrap: 'wrap' }}>
      <div style={{ width: 140, height: 140, flex: '0 0 140px' }}>
        {total > 0 ? (
          <ResponsiveContainer minWidth={0} minHeight={0} initialDimension={{ width: 140, height: 140 }}>
            <PieChart>
              <Pie data={data} dataKey="value" nameKey="name" innerRadius={42} outerRadius={62} isAnimationActive={false}>
                {data.map((entry) => <Cell key={entry.name} fill={entry.color} />)}
              </Pie>
              <RechartsTooltip contentStyle={{ background: '#141414', border: '1px solid #303030', borderRadius: 6 }} />
            </PieChart>
          </ResponsiveContainer>
        ) : <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={false} />}
      </div>
      <Space direction="vertical" size={8} style={{ flex: '1 1 140px', minWidth: 140 }}>
        <Space style={{ justifyContent: 'space-between', width: '100%' }}>
          <Text strong>{title}</Text><Text type="secondary">{total} total</Text>
        </Space>
        {data.map((item) => (
          <Space key={item.name} style={{ justifyContent: 'space-between', width: '100%' }}>
            <Badge color={item.color} text={item.name} /><Text strong>{item.value}</Text>
          </Space>
        ))}
      </Space>
    </div>
  );
};

const protocolData = (counts: Record<string, number> = {}) => Object.entries(counts)
  .filter(([, value]) => value > 0)
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([name, value]) => ({ name, value, color: protocolColors[name] || '#722ed1' }));

const Dashboard = (): JSX.Element => {
  const initData = useInit();
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshCountdown, setRefreshCountdown] = useState(AUTO_REFRESH_SECONDS);
  const requestInFlight = useRef(false);

  const loadDashboard = useCallback(async () => {
    if (requestInFlight.current) return;
    requestInFlight.current = true;
    setLoading(true);
    setError(null);
    try {
      const payload = await dashboardApi.get();
      setData(payload as DashboardData);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : 'Failed to load dashboard');
    } finally {
      requestInFlight.current = false;
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadDashboard();
  }, [loadDashboard]);

  useEffect(() => {
    const timer = window.setInterval(() => {
      setRefreshCountdown((current) => {
        if (current <= 1) {
          void loadDashboard();
          return AUTO_REFRESH_SECONDS;
        }
        return current - 1;
      });
    }, 1_000);

    return () => window.clearInterval(timer);
  }, [loadDashboard]);

  const refreshNow = useCallback(() => {
    setRefreshCountdown(AUTO_REFRESH_SECONDS);
    void loadDashboard();
  }, [loadDashboard]);

  const routeStatusData = useMemo(() => statusOrder
    .map((status) => ({ name: statusMeta[status].label, key: status, value: data?.routes.statuses[status] || 0, color: statusMeta[status].color }))
    .filter((item) => item.value > 0), [data]);

  const sourceProtocolData = useMemo(() => protocolData(data?.routes.source_protocols), [data]);
  const destinationProtocolData = useMemo(() => protocolData(data?.routes.destination_protocols), [data]);

  const networkSeries = useMemo(() => (data?.network_series || []).map((point) => ({
    ...point,
    time: formatTime(point.timestamp),
  })), [data]);

  const statusSeries = useMemo(() => (data?.status_series || []).map((point) => ({
    ...point,
    time: formatTime(String(point.timestamp)),
  })), [data]);

  const routeColumns: ColumnsType<AttentionRow> = [
    {
      title: 'Route',
      dataIndex: 'name',
      key: 'name',
      render: (value: string, row) => (
        <Space direction="vertical" size={0}>
          <Text strong>{value}</Text>
          <Text type="secondary">
            {row.last_event?.message || row.last_event?.reason || 'Current route state'}
            {row.last_event?.ts ? ` · ${formatRelativeTime(row.last_event.ts)}` : ''}
          </Text>
        </Space>
      ),
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
      render: (status: StatusKey) => <Tag color={statusMeta[status]?.color || statusMeta.other.color}>{statusMeta[status]?.label || status}</Tag>,
    },
    {
      title: 'Path',
      key: 'path',
      render: (_, row) => (
        <Space size={4} wrap>
          {(row.source_protocols || []).map((protocol) => <Tag key={`source-${protocol}`} color={protocolColors[protocol]}>{protocol}</Tag>)}
          <Text type="secondary">to</Text>
          {(row.destination_protocols || []).map((protocol) => <Tag key={`destination-${protocol}`} color={protocolColors[protocol]}>{protocol}</Tag>)}
        </Space>
      ),
    },
    { title: 'Signal', dataIndex: 'signal', key: 'signal' },
  ];

  if (!data && loading) {
    return <div style={{ minHeight: 420, display: 'grid', placeItems: 'center' }}><Spin size="large" /></div>;
  }

  if (!data) {
    return (
      <Space direction="vertical" size={20} style={{ width: '100%' }}>
        <Title level={2} style={{ margin: 0 }}>Dashboard</Title>
        <Alert
          type="error"
          showIcon
          message={error || 'Failed to load dashboard'}
          action={<Button onClick={refreshNow}>Retry</Button>}
        />
      </Space>
    );
  }

  const system = data.system;
  const storage = system?.storage;
  const routeTotal = data.routes.total || 0;

  return (
    <Space direction="vertical" size={20} style={{ width: '100%' }}>
      <Space align="center" style={{ justifyContent: 'space-between', width: '100%' }} wrap>
        <Title level={2} style={{ margin: 0 }}>Dashboard</Title>
        <Button icon={<ReloadOutlined />} loading={loading} onClick={refreshNow}>
          Refresh in {refreshCountdown}s
        </Button>
      </Space>

      {error && <Alert type="error" showIcon message={error} action={<Button size="small" onClick={refreshNow}>Retry</Button>} />}
      {data && !data.analytics_available && (
        <Alert type="warning" showIcon message="Historical analytics are temporarily unavailable. Current system and route state is still shown." />
      )}

      <Row gutter={[16, 16]}>
        <Col xs={24} md={12} xl={6}>
          <SummaryCard
            icon={<CloudServerOutlined />}
            title="System"
            value={`Uptime ${formatUptime(initData.app_started_at)} (v${initData.version})`}
            color="#1677ff"
          >
            <Space direction="vertical" size={8} style={{ width: '100%' }}>
              <Text type="secondary">
                {system?.cpu_count ?? 'N/A'} CPU · {formatBytes(system?.memory_total_bytes)} RAM · {formatBytes(storage?.total_bytes)} disk
              </Text>
              <ResourceLine label="CPU" percent={system?.cpu_percent} color="#fa8c16" />
              <ResourceLine label="RAM" percent={system?.memory_percent} color="#1677ff" />
              <ResourceLine label="Disk" percent={storage?.used_percent} color="#13c2c2" />
            </Space>
          </SummaryCard>
        </Col>

        <Col xs={24} md={12} xl={6}>
          <Card title={<Space><ForkOutlined />Routes</Space>} extra={<Text type="secondary">{routeTotal} total</Text>} style={cardStyle}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 16, minHeight: 132 }}>
              <div style={{ width: 132, height: 132, flex: '0 0 132px' }}>
                {routeTotal > 0 ? (
                  <ResponsiveContainer minWidth={0} minHeight={0} initialDimension={{ width: 132, height: 132 }}>
                    <PieChart>
                      <Pie data={routeStatusData} dataKey="value" nameKey="name" innerRadius={38} outerRadius={56} isAnimationActive={false}>
                        {routeStatusData.map((entry) => <Cell key={entry.key} fill={entry.color} />)}
                      </Pie>
                      <RechartsTooltip contentStyle={{ background: '#141414', border: '1px solid #303030', borderRadius: 6 }} />
                    </PieChart>
                  </ResponsiveContainer>
                ) : <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={false} />}
              </div>
              <Space direction="vertical" size={8} style={{ flex: 1, minWidth: 0 }}>
                {routeStatusData.map((item) => (
                  <Space key={item.key} style={{ justifyContent: 'space-between', width: '100%' }}>
                    <Badge color={item.color} text={item.name} /><Text strong>{item.value}</Text>
                  </Space>
                ))}
              </Space>
            </div>
          </Card>
        </Col>

        <Col xs={24} md={12} xl={6}>
          <SummaryCard icon={<CheckCircleOutlined />} title="Failover" value={`${data?.failover.on_backup || 0} on backup`} color="#faad14">
            <Space direction="vertical" size={8} style={{ width: '100%' }}>
              <SummaryLine label="Backup unavailable" value={String(data?.failover.backup_unavailable || 0)} danger={(data?.failover.backup_unavailable || 0) > 0} />
              <SummaryLine label="Last failover" value={formatRelativeTime(data?.failover.last_failover_at)} />
              <SummaryLine label="Failback events" value={`${data?.failover.failbacks_today || 0} today`} />
            </Space>
          </SummaryCard>
        </Col>

        <Col xs={24} md={12} xl={6}>
          <SummaryCard icon={<WarningOutlined />} title="Pipeline logs" value="Last 5m" color={(data?.logs.errors || 0) > 0 ? '#ff4d4f' : '#52c41a'}>
            <Space direction="vertical" size={8} style={{ width: '100%' }}>
              <SummaryLine label="Errors" value={String(data?.logs.errors || 0)} danger={(data?.logs.errors || 0) > 0} />
              <SummaryLine label="Warnings" value={String(data?.logs.warnings || 0)} danger={(data?.logs.warnings || 0) > 0} />
              <SummaryLine label="Info" value={String(data?.logs.info || 0)} />
              <Text type="secondary" ellipsis={{ tooltip: data?.logs.last_error_message || undefined }}>
                Last error: {data?.logs.last_error_at ? formatRelativeTime(data.logs.last_error_at) : 'none in last 5m'}
              </Text>
            </Space>
          </SummaryCard>
        </Col>
      </Row>

      <Row gutter={[16, 16]}>
        <Col xs={24} xl={12}>
          <Card
            title={<Space><LineChartOutlined />Network</Space>}
            style={cardStyle}
          >
            <Space size={12} wrap style={{ marginBottom: 8 }}>
              <Text type="secondary">IN {formatBitrate(system?.network_in_bytes_per_sec)}</Text>
              <Text type="secondary">OUT {formatBitrate(system?.network_out_bytes_per_sec)}</Text>
            </Space>
            <div style={{ width: '100%', height: 240 }}>
              {networkSeries.length > 0 ? (
                <ResponsiveContainer minWidth={0} minHeight={0} initialDimension={{ width: 600, height: 240 }}>
                  <AreaChart data={networkSeries} margin={{ top: 8, right: 18, left: 10, bottom: 0 }}>
                    <defs>
                      <linearGradient id="dashboardInput" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#13c2c2" stopOpacity={0.42} /><stop offset="95%" stopColor="#13c2c2" stopOpacity={0.04} /></linearGradient>
                      <linearGradient id="dashboardOutput" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#9254de" stopOpacity={0.36} /><stop offset="95%" stopColor="#9254de" stopOpacity={0.04} /></linearGradient>
                    </defs>
                    <CartesianGrid {...chartGridStyle} />
                    <XAxis dataKey="time" stroke="#8c8c8c" />
                    <YAxis stroke="#8c8c8c" width={76} tickFormatter={(value) => formatBitrate(value)} />
                    <RechartsTooltip contentStyle={{ background: '#141414', border: '1px solid #303030', borderRadius: 6 }} formatter={(value) => [formatBitrate(Number(value)), '']} />
                    <Area type="monotone" dataKey="input" name="Interface in" stroke="#13c2c2" fill="url(#dashboardInput)" isAnimationActive={false} />
                    <Area type="monotone" dataKey="output" name="Interface out" stroke="#9254de" fill="url(#dashboardOutput)" isAnimationActive={false} />
                  </AreaChart>
                </ResponsiveContainer>
              ) : <Empty description="No network analytics in the last hour" />}
            </div>
          </Card>
        </Col>

        <Col xs={24} xl={12}>
          <Card title={<Space><FieldTimeOutlined />Routes by status</Space>} style={cardStyle}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <div style={{ flex: '1 1 0', height: 240, minWidth: 0 }}>
                {statusSeries.length > 0 ? (
                  <ResponsiveContainer minWidth={0} minHeight={0} initialDimension={{ width: 500, height: 240 }}>
                    <LineChart data={statusSeries} margin={{ top: 8, right: 2, left: -8, bottom: 0 }}>
                      <CartesianGrid {...chartGridStyle} />
                      <XAxis dataKey="time" stroke="#8c8c8c" />
                      <YAxis stroke="#8c8c8c" allowDecimals={false} width={36} />
                      <RechartsTooltip contentStyle={{ background: '#141414', border: '1px solid #303030', borderRadius: 6 }} />
                      {statusOrder.map((status) => <Line key={status} type="stepAfter" dataKey={status} name={statusMeta[status].label} stroke={statusMeta[status].color} dot={false} isAnimationActive={false} />)}
                    </LineChart>
                  </ResponsiveContainer>
                ) : <Empty description="No status analytics in the last hour" />}
              </div>
              <Space direction="vertical" size={6} style={{ flex: '0 0 140px' }}>
                {routeStatusData.map((item) => (
                  <Space key={item.key} style={{ justifyContent: 'space-between', width: '100%' }}>
                    <Badge color={item.color} text={item.name} /><Text strong>{item.value}</Text>
                  </Space>
                ))}
              </Space>
            </div>
          </Card>
        </Col>
      </Row>

      <Row gutter={[16, 16]}>
        <Col xs={24} xl={12}>
          <Card title={<Space><ApiOutlined />Protocol split</Space>} style={cardStyle}>
            <div style={{ display: 'flex', gap: 40, flexWrap: 'wrap' }}>
              <ProtocolDonut title="Sources" data={sourceProtocolData} />
              <ProtocolDonut title="Destinations" data={destinationProtocolData} />
            </div>
          </Card>
        </Col>
        <Col xs={24} xl={12}>
          <Card title="Routes needing attention" style={cardStyle}>
            <Table
              rowKey="id"
              columns={routeColumns}
              dataSource={data?.attention || []}
              pagination={false}
              size="small"
              scroll={{ x: 760 }}
              locale={{ emptyText: <Empty description="No routes need attention" /> }}
            />
          </Card>
        </Col>
      </Row>
    </Space>
  );
};

export default Dashboard;
