import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, Button, Card, Col, DatePicker, Empty, Row, Select, Space, Typography } from 'antd';
import { ArrowLeftOutlined, HomeOutlined, ReloadOutlined } from '@ant-design/icons';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import dayjs from 'dayjs';
import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip as RechartsTooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { interfacesApi, nodesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

const LIVE_ANALYTICS_WINDOW = 'live';
const CUSTOM_ANALYTICS_WINDOW = 'custom';
const LIVE_WINDOW_MINUTES = 5;
const LIVE_REFRESH_INTERVAL_MS = 5_000;
const CHART_GRID_STYLE = {
  stroke: '#4f4f4f',
  strokeWidth: 0.6,
  strokeDasharray: '2 4',
};

const ANALYTICS_WINDOW_OPTIONS = [
  { label: 'live', value: LIVE_ANALYTICS_WINDOW },
  { label: 'last 30 min', value: 'last_30_min' },
  { label: 'last hour', value: 'last_hour' },
  { label: 'last 6 hour', value: 'last_6_hour' },
  { label: 'last 24 hour', value: 'last_24_hour' },
  { label: 'custom range', value: CUSTOM_ANALYTICS_WINDOW },
];
const ANALYTICS_WINDOW_VALUES = new Set(ANALYTICS_WINDOW_OPTIONS.map((item) => item.value));

const formatChartTimestamp = (value, includeSeconds = false) => {
  if (!value) return '';
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return '';

  const pad = (input) => String(input).padStart(2, '0');
  const hours = pad(parsed.getHours());
  const minutes = pad(parsed.getMinutes());
  if (!includeSeconds) return `${hours}:${minutes}`;
  return `${hours}:${minutes}:${pad(parsed.getSeconds())}`;
};

const formatBitrate = (bytesPerSec) => {
  if (typeof bytesPerSec !== 'number' || Number.isNaN(bytesPerSec)) return '-';

  const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  let value = Math.max(0, bytesPerSec * 8);
  let unitIndex = 0;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }

  const digits = value >= 100 || unitIndex === 0 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(digits)} ${units[unitIndex]}`;
};

const formatSignedThroughput = (bytesPerSec) => {
  if (typeof bytesPerSec !== 'number' || Number.isNaN(bytesPerSec)) return '-';
  const sign = bytesPerSec < 0 ? '-' : '';
  return `${sign}${formatBitrate(Math.abs(bytesPerSec))}`;
};

const formatRoundedMetricValue = (value) => {
  if (typeof value !== 'number' || Number.isNaN(value)) return value;
  return Math.round(value);
};

const calcAverage = (values) => {
  const nums = values.filter((v) => typeof v === 'number' && !Number.isNaN(v));
  if (!nums.length) return null;
  return nums.reduce((sum, v) => sum + v, 0) / nums.length;
};

const formatOneDecimal = (value) => {
  if (typeof value !== 'number' || Number.isNaN(value)) return '-';
  return value.toFixed(1);
};

const renderChartTooltip = ({ active, payload }) => {
  if (!active || !Array.isArray(payload) || payload.length === 0) return null;

  const rawTimestamp = payload[0]?.payload?.timestamp;
  const timeLabel = formatChartTimestamp(rawTimestamp, true) || '-';

  const formatTooltipValue = (entry) => {
    const value = entry?.value;
    if (typeof value !== 'number' || Number.isNaN(value)) return value;
    if (String(entry?.dataKey || '').startsWith('net_')) {
      return formatSignedThroughput(value);
    }
    return formatRoundedMetricValue(value);
  };

  return (
    <div
      style={{
        background: '#141414',
        border: '1px solid #303030',
        borderRadius: 6,
        padding: '8px 10px',
      }}
    >
      <div style={{ color: '#bfbfbf', fontSize: 12, fontWeight: 700, marginBottom: 10 }}>
        {timeLabel}
      </div>
      {payload.map((entry) => (
        <div key={entry?.dataKey} style={{ color: entry?.color || '#d9d9d9', fontSize: 12 }}>
          {entry?.name}: {formatTooltipValue(entry)}
        </div>
      ))}
    </div>
  );
};

const alignTsToBucket = (tsMs, bucketMs) => Math.floor(tsMs / bucketMs) * bucketMs;

const SystemNodeMetrics = () => {
  const navigate = useNavigate();
  const { id } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const nodeId = decodeURIComponent(id || '');
  const [analyticsWindow, setAnalyticsWindow] = useState(LIVE_ANALYTICS_WINDOW);
  const [customRangeDraft, setCustomRangeDraft] = useState([
    dayjs().subtract(1, 'hour'),
    dayjs(),
  ]);
  const [customRangeApplied, setCustomRangeApplied] = useState([
    dayjs().subtract(1, 'hour'),
    dayjs(),
  ]);
  const [analyticsData, setAnalyticsData] = useState({ points: [], meta: null });
  const [analyticsLoading, setAnalyticsLoading] = useState(false);
  const [analyticsError, setAnalyticsError] = useState(null);
  const [analyticsRefreshTick, setAnalyticsRefreshTick] = useState(0);
  const [allowedInterfaces, setAllowedInterfaces] = useState([]);
  const [selectedNetworkInterfaces, setSelectedNetworkInterfaces] = useState([]);
  const didInitFromUrlRef = useRef(false);

  useEffect(() => {
    if (!window.setBreadcrumbItems) return;

    window.setBreadcrumbItems([
      {
        href: ROUTES.ROUTES,
        title: <HomeOutlined />,
      },
      {
        href: ROUTES.SYSTEM_NODES,
        title: 'Nodes List',
      },
      {
        title: nodeId || 'Node Metrics',
      },
    ]);
  }, [nodeId]);

  useEffect(() => {
    if (didInitFromUrlRef.current) return;
    didInitFromUrlRef.current = true;

    const timeFromUrl = searchParams.get('time');
    if (timeFromUrl && ANALYTICS_WINDOW_VALUES.has(timeFromUrl)) {
      setAnalyticsWindow(timeFromUrl);
    }

    const networkFromUrl = searchParams.get('network');
    if (networkFromUrl) {
      const selected = networkFromUrl
        .split(',')
        .map((v) => v.trim())
        .filter(Boolean);
      setSelectedNetworkInterfaces(Array.from(new Set(selected)));
    }
  }, [searchParams]);

  useEffect(() => {
    let mounted = true;

    const loadRouteVisibleInterfaces = async () => {
      try {
        const [savedResult, systemResult] = await Promise.all([
          interfacesApi.getAll(),
          interfacesApi.getSystemInterfaces(),
        ]);
        const saved = Array.isArray(savedResult?.data) ? savedResult.data : [];
        const system = Array.isArray(systemResult?.data) ? systemResult.data : [];

        const savedBySysName = saved.reduce((acc, item) => {
          if (item?.sys_name) {
            acc[item.sys_name] = item;
          }
          return acc;
        }, {});

        const mergedRows = [
          ...system.map((item) => {
            const aliasRecord = savedBySysName[item.sys_name];
            return {
              sys_name: item.sys_name,
              enabled: aliasRecord?.enabled ?? true,
            };
          }),
          ...saved
            .filter((item) => !system.some((systemItem) => systemItem.sys_name === item.sys_name))
            .map((item) => ({
              sys_name: item.sys_name,
              enabled: item.enabled ?? true,
            })),
        ];

        const names = mergedRows
          .filter((item) => item?.enabled !== false && item?.sys_name)
          .map((item) => item.sys_name);

        if (mounted) {
          setAllowedInterfaces(Array.from(new Set(names)));
        }
      } catch {
        if (mounted) {
          setAllowedInterfaces([]);
        }
      }
    };

    loadRouteVisibleInterfaces();
    return () => {
      mounted = false;
    };
  }, []);

  const fetchAnalyticsData = useCallback(async (queryParams) => {
    if (!nodeId) return;

    setAnalyticsLoading(true);
    setAnalyticsError(null);

    try {
      const result = await nodesApi.getAnalytics(nodeId, queryParams);
      if (result?.error) {
        throw new Error(result.error);
      }

      setAnalyticsData({
        points: Array.isArray(result?.points) ? result.points : [],
        meta: result?.meta || null,
      });
    } catch (error) {
      setAnalyticsError(error.message || 'Failed to load analytics data');
      setAnalyticsData({ points: [], meta: null });
    } finally {
      setAnalyticsLoading(false);
    }
  }, [nodeId]);

  useEffect(() => {
    if (!nodeId) return;

    const queryParams = {};
    if (analyticsWindow === LIVE_ANALYTICS_WINDOW) {
      const liveTo = dayjs();
      const liveFrom = liveTo.subtract(LIVE_WINDOW_MINUTES, 'minute');
      queryParams.from = liveFrom.toISOString();
      queryParams.to = liveTo.toISOString();
    } else if (analyticsWindow === CUSTOM_ANALYTICS_WINDOW) {
      const [from, to] = customRangeApplied;
      if (from && to) {
        queryParams.from = from.toDate().toISOString();
        queryParams.to = to.toDate().toISOString();
      }
    } else {
      queryParams.window = analyticsWindow;
    }

    fetchAnalyticsData(queryParams);
  }, [analyticsWindow, customRangeApplied, analyticsRefreshTick, fetchAnalyticsData, nodeId]);

  useEffect(() => {
    if (!nodeId || analyticsWindow !== LIVE_ANALYTICS_WINDOW) {
      return undefined;
    }

    const timer = window.setInterval(() => {
      setAnalyticsRefreshTick((prev) => prev + 1);
    }, LIVE_REFRESH_INTERVAL_MS);

    return () => window.clearInterval(timer);
  }, [nodeId, analyticsWindow]);

  const applyCustomRange = () => {
    if (!customRangeDraft[0] || !customRangeDraft[1]) return;
    setCustomRangeApplied(customRangeDraft);
  };

  const chartData = useMemo(() => {
    const rawPoints = analyticsData?.points || [];
    const meta = analyticsData?.meta || null;
    const bucketMs = Number(meta?.bucket_ms) || 0;

    const normalizePoint = (point) => {
      const nextPoint = {
        ...point,
        xLabel: formatChartTimestamp(point.timestamp, analyticsWindow === LIVE_ANALYTICS_WINDOW),
      };

      Object.keys(nextPoint).forEach((key) => {
        if (!key.startsWith('net_out_')) return;
        const value = nextPoint[key];
        if (typeof value === 'number' && !Number.isNaN(value)) {
          nextPoint[key] = -Math.abs(value);
        }
      });

      return nextPoint;
    };

    if (!meta?.from || !meta?.to || bucketMs <= 0) {
      return rawPoints.map(normalizePoint);
    }

    const fromMs = Date.parse(meta.from);
    const toMs = Date.parse(meta.to);
    if (Number.isNaN(fromMs) || Number.isNaN(toMs) || toMs < fromMs) {
      return rawPoints.map(normalizePoint);
    }

    const seriesKeys = new Set();
    rawPoints.forEach((point) => {
      Object.keys(point || {}).forEach((key) => {
        if (key.startsWith('net_in_') || key.startsWith('net_out_')) {
          seriesKeys.add(key);
        }
      });
    });

    const pointsByBucket = new Map();
    rawPoints.forEach((point) => {
      const pointMs = Date.parse(point?.timestamp || '');
      if (Number.isNaN(pointMs)) return;
      const bucketTsMs = alignTsToBucket(pointMs, bucketMs);
      const bucketIso = new Date(bucketTsMs).toISOString();
      pointsByBucket.set(bucketIso, point);
    });

    const dense = [];
    const startMs = alignTsToBucket(fromMs, bucketMs);
    const endMs = alignTsToBucket(toMs, bucketMs);

    for (let ts = startMs; ts <= endMs; ts += bucketMs) {
      const iso = new Date(ts).toISOString();
      const source = pointsByBucket.get(iso) || null;
      const row = {
        timestamp: iso,
        cpu: source?.cpu ?? null,
        ram: source?.ram ?? null,
        swap: source?.swap ?? null,
        la_avg1: source?.la_avg1 ?? null,
        la_avg5: source?.la_avg5 ?? null,
        la_avg15: source?.la_avg15 ?? null,
      };

      seriesKeys.forEach((key) => {
        row[key] = source?.[key] ?? null;
      });

      dense.push(row);
    }

    return dense.map(normalizePoint);
  }, [analyticsData?.meta, analyticsData?.points, analyticsWindow]);

  const networkSeries = useMemo(() => {
    if (!chartData.length) return [];
    const allowedSet = new Set(allowedInterfaces);
    const keys = new Set();
    chartData.forEach((point) => {
      Object.keys(point).forEach((key) => {
        if (!key.startsWith('net_in_') && !key.startsWith('net_out_')) return;
        const iface = key.replace('net_in_', '').replace('net_out_', '');
        if (!allowedSet.has(iface)) return;
        keys.add(key);
      });
    });
    return Array.from(keys).sort();
  }, [allowedInterfaces, chartData]);

  const networkChartData = useMemo(() => {
    return chartData.map((point) => {
      const next = { ...point };
      let totalIn = 0;
      let totalOut = 0;

      networkSeries.forEach((key) => {
        const value = next[key];
        if (typeof value !== 'number' || Number.isNaN(value)) return;
        if (key.startsWith('net_in_')) totalIn += value;
        if (key.startsWith('net_out_')) totalOut += value;
      });

      next.net_total_in = totalIn;
      next.net_total_out = totalOut;
      return next;
    });
  }, [chartData, networkSeries]);

  const renderedNetworkSeries = useMemo(() => {
    if (!selectedNetworkInterfaces.length) {
      const allInterfaces = Array.from(
        new Set(networkSeries.map((key) => key.replace('net_in_', '').replace('net_out_', '')))
      );

      return allInterfaces.flatMap((iface) => [`net_in_${iface}`, `net_out_${iface}`]);
    }

    return selectedNetworkInterfaces.flatMap((iface) => [`net_in_${iface}`, `net_out_${iface}`]);
  }, [networkSeries, selectedNetworkInterfaces]);

  const networkInterfaceOptions = useMemo(() => {
    const names = networkSeries
      .map((key) => key.replace('net_in_', '').replace('net_out_', ''))
      .filter(Boolean);

    const unique = Array.from(new Set(names)).sort();
    return unique.map((name) => ({ label: name, value: name }));
  }, [networkSeries]);

  useEffect(() => {
    setSelectedNetworkInterfaces((prev) =>
      prev.filter((iface) => networkInterfaceOptions.some((item) => item.value === iface))
    );
  }, [networkInterfaceOptions]);

  useEffect(() => {
    const nextParams = new URLSearchParams(searchParams);
    nextParams.set('time', analyticsWindow);

    if (selectedNetworkInterfaces.length > 0) {
      nextParams.set('network', selectedNetworkInterfaces.join(','));
    } else {
      nextParams.delete('network');
    }

    const current = searchParams.toString();
    const next = nextParams.toString();
    if (current !== next) {
      setSearchParams(nextParams, { replace: true });
    }
  }, [analyticsWindow, searchParams, selectedNetworkInterfaces, setSearchParams]);

  const networkDomain = useMemo(() => {
    const values = [];
    networkChartData.forEach((point) => {
      renderedNetworkSeries.forEach((key) => {
        const value = point?.[key];
        if (typeof value === 'number' && !Number.isNaN(value)) {
          values.push(Math.abs(value));
        }
      });
    });

    if (values.length === 0) {
      return [-1, 1];
    }

    const sorted = [...values].sort((a, b) => a - b);
    const p95Index = Math.max(0, Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95)));
    const chosen = sorted[p95Index] || sorted[sorted.length - 1] || 1;
    const domainMax = Math.max(chosen, 1);
    return [-domainMax, domainMax];
  }, [networkChartData, renderedNetworkSeries]);

  const networkPeaks = useMemo(() => {
    let maxIn = 0;
    let maxOut = 0;
    networkChartData.forEach((point) => {
      renderedNetworkSeries.forEach((key) => {
        const value = point?.[key];
        if (typeof value !== 'number' || Number.isNaN(value)) return;
        if (key === 'net_total_in' || key.startsWith('net_in_')) {
          maxIn = Math.max(maxIn, Math.abs(value));
        } else if (key === 'net_total_out' || key.startsWith('net_out_')) {
          maxOut = Math.max(maxOut, Math.abs(value));
        }
      });
    });
    return { maxIn, maxOut };
  }, [networkChartData, renderedNetworkSeries]);

  const averageMetrics = useMemo(() => {
    const cpu = calcAverage(chartData.map((p) => p.cpu));
    const ram = calcAverage(chartData.map((p) => p.ram));
    const swap = calcAverage(chartData.map((p) => p.swap));
    const la1 = calcAverage(chartData.map((p) => p.la_avg1));
    const la5 = calcAverage(chartData.map((p) => p.la_avg5));
    const la15 = calcAverage(chartData.map((p) => p.la_avg15));
    const netIn = calcAverage(networkChartData.map((p) => p.net_total_in));
    const netOut = calcAverage(networkChartData.map((p) => p.net_total_out));

    return { cpu, ram, swap, la1, la5, la15, netIn, netOut };
  }, [chartData, networkChartData]);

  return (
    <Space
      direction="vertical"
      size="large"
      style={{ width: '100%', maxWidth: 1200, margin: '0 auto' }}
    >
      <Row justify="space-between" align="middle" gutter={[16, 16]}>
        <Col flex="auto">
          <Space align="center" size="middle" wrap>
            <Button
              icon={<ArrowLeftOutlined />}
              onClick={() => navigate(ROUTES.SYSTEM_NODES)}
            >
              Back
            </Button>
            <Title level={3} style={{ margin: 0, fontSize: '1.75rem', fontWeight: 600 }}>
              {nodeId}
            </Title>
          </Space>
        </Col>
      </Row>

      <Card
        extra={(
          <Space wrap>
            <Select
              value={analyticsWindow}
              onChange={setAnalyticsWindow}
              options={ANALYTICS_WINDOW_OPTIONS}
              style={{ minWidth: 180 }}
            />
            <Button
              icon={<ReloadOutlined />}
              onClick={() => setAnalyticsRefreshTick((prev) => prev + 1)}
              loading={analyticsLoading}
              disabled={analyticsWindow === LIVE_ANALYTICS_WINDOW}
            >
              Refresh
            </Button>
            {analyticsWindow === CUSTOM_ANALYTICS_WINDOW && (
              <>
                <DatePicker
                  showTime
                  value={customRangeDraft[0]}
                  onChange={(value) => setCustomRangeDraft((prev) => [value, prev[1]])}
                  placeholder="Start time"
                />
                <DatePicker
                  showTime
                  value={customRangeDraft[1]}
                  onChange={(value) => setCustomRangeDraft((prev) => [prev[0], value])}
                  placeholder="End time"
                />
                <Button onClick={applyCustomRange}>Apply</Button>
              </>
            )}
          </Space>
        )}
      >
        <Space direction="vertical" size="middle" style={{ width: '100%' }}>
          {analyticsError && <Alert type="error" showIcon message={analyticsError} />}
          {!analyticsError && !analyticsLoading && chartData.length === 0 && (
            <Empty description="No analytics data for selected period" />
          )}

          <Row gutter={[16, 16]}>
            <Col xs={24} lg={12}>
              <Card
                size="small"
                title={`CPU usage${averageMetrics.cpu != null ? `: ${Math.round(averageMetrics.cpu)}%` : ''}`}
              >
                <div style={{ width: '100%', height: 260 }}>
                  <ResponsiveContainer>
                    <LineChart data={chartData} margin={{ top: 8, right: 20, left: 8, bottom: 8 }}>
                      <CartesianGrid {...CHART_GRID_STYLE} />
                      <XAxis dataKey="xLabel" />
                      <YAxis width={56} domain={[0, 100]} />
                      <RechartsTooltip content={renderChartTooltip} />
                      <Line type="monotone" dataKey="cpu" name="CPU %" stroke="#1677ff" dot={false} isAnimationActive={false} connectNulls />
                    </LineChart>
                  </ResponsiveContainer>
                </div>
              </Card>
            </Col>

            <Col xs={24} lg={12}>
              <Card
                size="small"
                title={`LA${
                  averageMetrics.la1 != null && averageMetrics.la5 != null && averageMetrics.la15 != null
                    ? `: ${formatOneDecimal(averageMetrics.la1)}/${formatOneDecimal(averageMetrics.la5)}/${formatOneDecimal(averageMetrics.la15)}`
                    : ''
                }`}
              >
                <div style={{ width: '100%', height: 260 }}>
                  <ResponsiveContainer>
                    <LineChart data={chartData} margin={{ top: 8, right: 20, left: 8, bottom: 8 }}>
                      <CartesianGrid {...CHART_GRID_STYLE} />
                      <XAxis dataKey="xLabel" />
                      <YAxis width={56} />
                      <RechartsTooltip content={renderChartTooltip} />
                      <Line type="monotone" dataKey="la_avg1" name="avg1" stroke="#52c41a" dot={false} isAnimationActive={false} connectNulls />
                      <Line type="monotone" dataKey="la_avg5" name="avg5" stroke="#faad14" dot={false} isAnimationActive={false} connectNulls />
                      <Line type="monotone" dataKey="la_avg15" name="avg15" stroke="#f5222d" dot={false} isAnimationActive={false} connectNulls />
                    </LineChart>
                  </ResponsiveContainer>
                </div>
              </Card>
            </Col>

            <Col xs={24} lg={12}>
              <Card
                size="small"
                title={`Memory${
                  averageMetrics.ram != null && averageMetrics.swap != null
                    ? `: RAM ${Math.round(averageMetrics.ram)}%, SWAP ${Math.round(averageMetrics.swap)}%`
                    : ''
                }`}
              >
                <div style={{ width: '100%', height: 260 }}>
                  <ResponsiveContainer>
                    <LineChart data={chartData} margin={{ top: 8, right: 20, left: 8, bottom: 8 }}>
                      <CartesianGrid {...CHART_GRID_STYLE} />
                      <XAxis dataKey="xLabel" />
                      <YAxis width={56} domain={[0, 100]} />
                      <RechartsTooltip content={renderChartTooltip} />
                      <Line type="monotone" dataKey="ram" name="RAM %" stroke="#722ed1" dot={false} isAnimationActive={false} connectNulls />
                      <Line type="monotone" dataKey="swap" name="SWAP %" stroke="#13c2c2" dot={false} isAnimationActive={false} connectNulls />
                    </LineChart>
                  </ResponsiveContainer>
                </div>
              </Card>
            </Col>

            <Col xs={24} lg={12}>
              <Card
                size="small"
                title={`Network${
                  averageMetrics.netIn != null && averageMetrics.netOut != null
                    ? `: in ${formatBitrate(averageMetrics.netIn)}, out ${formatBitrate(Math.abs(averageMetrics.netOut))}`
                    : ''
                }`}
              >
                <Space size={12} style={{ marginBottom: 8 }}>
                  <Select
                    size="small"
                    mode="multiple"
                    allowClear
                    placeholder="All selected interfaces"
                    value={selectedNetworkInterfaces}
                    onChange={setSelectedNetworkInterfaces}
                    options={networkInterfaceOptions}
                    style={{ minWidth: 260 }}
                  />
                  <span style={{ color: '#8c8c8c', fontSize: 12 }}>
                    peak in: {formatBitrate(networkPeaks.maxIn)} | peak out: {formatBitrate(networkPeaks.maxOut)}
                  </span>
                </Space>
              <div style={{ width: '100%', height: 260 }}>
                  <ResponsiveContainer>
                    <LineChart data={networkChartData} margin={{ top: 8, right: 20, left: 8, bottom: 8 }}>
                      <CartesianGrid {...CHART_GRID_STYLE} />
                      <XAxis dataKey="xLabel" />
                      <YAxis
                        width={80}
                        domain={networkDomain}
                        tickFormatter={(value) => formatSignedThroughput(value)}
                      />
                      <RechartsTooltip content={renderChartTooltip} />
                      {renderedNetworkSeries.map((key, index) => (
                        <Line
                          key={key}
                          type="monotone"
                          dataKey={key}
                          name={
                            key === 'net_total_in'
                              ? 'total in'
                              : key === 'net_total_out'
                                ? 'total out'
                                : key.replace('net_in_', '').replace('net_out_', '') + (key.startsWith('net_in_') ? ' in' : ' out')
                          }
                          stroke={['#13c2c2', '#2f54eb', '#eb2f96', '#fa8c16', '#a0d911', '#1677ff'][index % 6]}
                          dot={false}
                          isAnimationActive={false}
                          connectNulls
                        />
                      ))}
                    </LineChart>
                  </ResponsiveContainer>
                </div>
                {renderedNetworkSeries.length > 0 && (
                  <div style={{ maxHeight: 100, overflowY: 'auto', marginTop: 8 }}>
                    <Space wrap size={[12, 8]}>
                      {renderedNetworkSeries.map((key, index) => {
                        const color = ['#13c2c2', '#2f54eb', '#eb2f96', '#fa8c16', '#a0d911', '#1677ff'][index % 6];
                        const label =
                          key === 'net_total_in'
                            ? 'total in'
                            : key === 'net_total_out'
                              ? 'total out'
                              : key.replace('net_in_', '').replace('net_out_', '') + (key.startsWith('net_in_') ? ' in' : ' out');
                        return (
                          <span key={`${key}-legend`} style={{ color }}>
                            {label}
                          </span>
                        );
                      })}
                    </Space>
                  </div>
                )}
              </Card>
            </Col>
          </Row>
        </Space>
      </Card>
    </Space>
  );
};

export default SystemNodeMetrics;
