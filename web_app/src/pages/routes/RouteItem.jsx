import { useEffect, useState } from 'react';
import {
  Card,
  Typography,
  Space,
  Tag,
  Row,
  Col,
  Button,
  Table,
  Modal,
  Collapse,
  message,
  Input,
  Tabs,
  Statistic,
  Dropdown,
  Tooltip as AntTooltip
} from 'antd';
import {
  PlayCircleOutlined,
  PauseCircleOutlined,
  EditOutlined,
  DeleteOutlined,
  PlusOutlined,
  ExclamationCircleFilled,
  HomeOutlined,
  LoadingOutlined,
  SearchOutlined,
  HolderOutlined,
  ArrowLeftOutlined
} from '@ant-design/icons';
import { useParams, useNavigate } from 'react-router-dom';
import { routesApi, destinationsApi } from '../../utils/api';
import { Socket } from "phoenix";
import { API_BASE_URL, ROUTES } from "../../utils/constants";
import { getToken } from "../../utils/auth";
import {
  ACTIVE_ROUTE_STATUSES,
  formatStatusLabel,
  isRouteBusy,
  resolvePendingRouteStatus,
} from "../../utils/routes";
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  AreaChart,
  Area
} from 'recharts';

const { Title, Text } = Typography;
const ROUTE_ACTION_POLL_ATTEMPTS = 5;
const ROUTE_ACTION_POLL_DELAY_MS = 250;

const getRuntimeStatusMeta = (status) => {
  switch ((status || '').toLowerCase()) {
    case 'processing':
    case 'started':
      return { color: 'success', label: status };
    case 'starting':
    case 'stopping':
    case 'reconnecting':
      return { color: 'processing', label: status };
    case 'failed':
      return { color: 'error', label: status };
    case 'stopped':
      return { color: 'default', label: status };
    default:
      return { color: 'default', label: status || 'unknown' };
  }
};

const getEndpointValue = (endpoint, key) => endpoint?.schema_options?.[key];

const getEndpointAddress = (endpoint) => {
  if (!endpoint) return 'N/A';

  switch (endpoint.schema) {
    case 'SRT':
      return `${getEndpointValue(endpoint, 'localaddress') || 'N/A'}:${getEndpointValue(endpoint, 'localport') || 'N/A'}`;
    case 'UDP':
      return `${getEndpointValue(endpoint, 'host') || getEndpointValue(endpoint, 'address') || 'N/A'}:${getEndpointValue(endpoint, 'port') || 'N/A'}`;
    default:
      return 'N/A';
  }
};

const getEndpointType = (endpoint) => {
  if (!endpoint) return 'N/A';

  if (endpoint.schema === 'SRT') {
    return getEndpointValue(endpoint, 'mode') || 'listener';
  }

  return endpoint.type || endpoint.role || endpoint.schema || 'N/A';
};

const getEndpointLatency = (endpoint) => {
  if (!endpoint) return null;
  const latency = endpoint.latency ?? getEndpointValue(endpoint, 'latency');
  return typeof latency === 'number' ? latency : null;
};

const formatLastUpdated = (date) => {
  if (!date) {
    return '-';
  }

  const parsedDate = new Date(date);

  if (Number.isNaN(parsedDate.getTime())) {
    return '-';
  }

  const pad = (value) => String(value).padStart(2, '0');

  const hours = pad(parsedDate.getHours());
  const minutes = pad(parsedDate.getMinutes());
  const seconds = pad(parsedDate.getSeconds());
  const day = pad(parsedDate.getDate());
  const month = pad(parsedDate.getMonth() + 1);
  const year = parsedDate.getFullYear();

  return `${hours}:${minutes}:${seconds} ${day}/${month}/${year}`;
};

const renderSrtModeTag = (mode) => {
  switch (mode) {
    case 'listener':
      return <Tag color="default">L</Tag>;
    case 'caller':
      return <Tag color="processing">C</Tag>;
    case 'rendezvous':
      return <Tag color="warning">R</Tag>;
    default:
      return null;
  }
};

const renderProtocolTag = (schema) => {
  switch (schema) {
    case 'SRT':
      return <Tag color="blue">SRT</Tag>;
    case 'UDP':
      return <Tag color="cyan">UDP</Tag>;
    default:
      return null;
  }
};

const sleep = (ms) => new Promise((resolve) => window.setTimeout(resolve, ms));

const hasRouteReachedActionResult = (route, action) => {
  const runtimeStatus = ((route?.schema_status || route?.status) || '').toLowerCase();

  if (action === 'start') {
    return ACTIVE_ROUTE_STATUSES.has(runtimeStatus);
  }

  return runtimeStatus === 'stopped' || runtimeStatus === 'failed';
};

const RouteItem = () => {
  const navigate = useNavigate();
  const { id } = useParams();
  const [routeData, setRouteData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const [destinationFilter, setDestinationFilter] = useState('');
  const [stats, setStats] = useState(null);
  const [statsHistory, setStatsHistory] = useState([]);
  const [activeStatsTab, setActiveStatsTab] = useState('overview');
  const [pendingAction, setPendingAction] = useState(null);

  // Phoenix Channel connection
  useEffect(() => {
    if (!id) return;

    // Create socket instance per-route to avoid module-level side effects (important for tests)
    const socket = new Socket(`${API_BASE_URL}/socket`, {
      params: { token: getToken()?.replace('Bearer ', '') }
    });

    // Connect to the socket
    socket.connect();

    // Join the channel for this specific route
    const channel = socket.channel(`live:${id}`);
    
    channel.join()
      .receive("ok", resp => {
        console.log("Successfully joined channel", resp);
      })
      .receive("error", resp => {
        console.error("Unable to join channel", resp);
        messageApi.error("Failed to connect to live updates");
      });

    // Listen for stats updates
    channel.on("stats", stats => {
      console.log("Received stats:", stats);
      setStats(stats);
      if (stats?.schema_status) {
        setRouteData((prev) => {
          if (!prev) {
            return prev;
          }

          return {
            ...prev,
            schema_status: resolvePendingRouteStatus(prev.schema_status, stats.schema_status, pendingAction),
          };
        });
      }
      // Add timestamp to stats for charts
      const timestamp = new Date().toLocaleTimeString();
      setStatsHistory(prev => {
        const next = [...prev, { ...stats, timestamp }];
        const MAX_POINTS = 300;
        return next.length > MAX_POINTS ? next.slice(next.length - MAX_POINTS) : next;
      });
    });

    // Cleanup on component unmount
    return () => {
      channel.off("stats");
      channel.leave();
      socket.disconnect();
      console.log("Channel cleanup completed");
    };
  }, [id, messageApi, pendingAction]);

  // Breadcrumb setup
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.ROUTES,
          title: 'Routes',
        },
        {
          title: loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
        }
      ]);
    }
  }, [id, routeData, loading]);

  // Fetch route data
  useEffect(() => {
    fetchRouteData();
  }, [id]);

  const fetchRouteData = async () => {
    try {
      const result = await routesApi.getById(id);
      const route = result.data;
      setRouteData(route);

      if (route?.stats && !stats) {
        setStats(route.stats);
      }

      if (Array.isArray(route?.stats_history) && route.stats_history.length > 0) {
        setStatsHistory(
          route.stats_history.map((entry) => ({
            ...(entry?.stats || {}),
            timestamp: entry?.inserted_at
              ? new Date(entry.inserted_at).toLocaleTimeString()
              : '',
          }))
        );
      }

      console.log("Route data:", route);
    } catch (error) {
      messageApi.error(`Failed to fetch route data: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const fetchRouteDataSnapshot = async () => {
    const result = await routesApi.getById(id);
    return result.data;
  };

  const refreshRouteUntilStable = async (action) => {
    for (let attempt = 0; attempt < ROUTE_ACTION_POLL_ATTEMPTS; attempt += 1) {
      const nextRoute = await fetchRouteDataSnapshot();
      setRouteData((prev) => ({
        ...nextRoute,
        schema_status: resolvePendingRouteStatus(prev?.schema_status, nextRoute?.schema_status, pendingAction || action),
      }));

      if (hasRouteReachedActionResult(nextRoute, action)) {
        return true;
      }

      if (attempt < ROUTE_ACTION_POLL_ATTEMPTS - 1) {
        await sleep(ROUTE_ACTION_POLL_DELAY_MS);
      }
    }

    return false;
  };

  // Status color and button mapping
  const getStatusDetails = (routeData) => {
    // First check if routeData exists
    if (!routeData) {
      return {
        color: 'default',
        buttonColor: 'default',
        buttonIcon: <PlayCircleOutlined />,
        buttonText: 'Start',
        buttonType: 'default'
      };
    }

    // Check if status field exists and use it as the primary indicator
    if (routeData.status) {
      const isStarted = routeData.status.toLowerCase() === 'started';

      if (isStarted) {
        return {
          color: 'success',
          buttonColor: 'default',
          buttonIcon: <PauseCircleOutlined />,
          buttonText: 'Stop',
          buttonType: 'default'
        };
      } else {
        return {
          color: 'error',
          buttonColor: 'primary',
          buttonIcon: <PlayCircleOutlined />,
          buttonText: 'Start',
          buttonType: 'primary'
        };
      }
    } else {
      // Fallback if status field is not available (should not happen)
      return {
        color: 'warning',
        buttonColor: 'primary',
        buttonIcon: <PlayCircleOutlined />,
        buttonText: 'Start',
        buttonType: 'primary'
      };
    }
  };

  const sourceRow = routeData ? {
    ...routeData,
    id: `source-${routeData.id}`,
    endpointId: routeData.id,
    role: 'Source',
    rowType: 'source',
    name: routeData.name || 'Source',
  } : null;
  const routeBusy = isRouteBusy(routeData);
  const deleteDisabledMessage = 'If you want to delete it, stop the route first';

  // Filter destinations
  const filteredDestinations = routeData?.destinations.filter(dest =>
    dest.name.toLowerCase().includes(destinationFilter.toLowerCase()) ||
    getEndpointAddress(dest).toLowerCase().includes(destinationFilter.toLowerCase())
  ) || [];

  const endpointsData = [
    ...(sourceRow ? [sourceRow] : []),
    ...filteredDestinations.map((dest) => ({
      ...dest,
      endpointId: dest.id,
      role: 'Destination',
      rowType: 'destination',
    })),
  ];

  const endpointColumns = [
    {
      title: 'Role',
      dataIndex: 'role',
      key: 'role',
      width: 130,
      render: (role) => (
        <Tag color={role === 'Source' ? 'geekblue' : 'default'}>
          {role}
        </Tag>
      ),
      filters: [
        { text: 'Source', value: 'Source' },
        { text: 'Destination', value: 'Destination' },
      ],
      onFilter: (value, record) => record.role === value,
    },
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => a.name.localeCompare(b.name),
      render: (text, record) => (
        <Space>
          <a href={record.rowType === 'source' ? `#/routes/${id}/edit` : `#/routes/${id}/destinations/${record.endpointId}/edit`}>
            {text}
          </a>
        </Space>
      ),
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      width: 120,
      render: (enabled) => (
        <Tag color={enabled ? 'success' : 'default'}>
          {enabled ? 'Yes' : 'No'}
        </Tag>
      ),
      filters: [
        { text: 'Enabled', value: true },
        { text: 'Disabled', value: false },
      ],
      onFilter: (value, record) => record.enabled === value,
    },
    {
      title: 'Status',
      key: 'status',
      width: 160,
      render: (_, record) => {
        const endpointStatus =
          record.rowType === 'source' ? (record.schema_status || record.status) : record.status;
        const { color, label } = getRuntimeStatusMeta(endpointStatus);

        return <Tag color={color}>{formatStatusLabel(label)}</Tag>;
      },
      filters: [
        { text: 'Started', value: 'started' },
        { text: 'Processing', value: 'processing' },
        { text: 'Reconnecting', value: 'reconnecting' },
        { text: 'Failed', value: 'failed' },
        { text: 'Stopped', value: 'stopped' },
      ],
      onFilter: (value, record) => {
        const endpointStatus =
          record.rowType === 'source' ? (record.schema_status || record.status) : record.status;

        return (endpointStatus || '').toLowerCase() === value;
      },
    },
    {
      title: 'Schema',
      dataIndex: 'schema',
      key: 'schema',
      filters: [
        { text: 'SRT', value: 'SRT' },
        { text: 'UDP', value: 'UDP' },
      ],
      onFilter: (value, record) => record.schema === value,
      render: (schema) => (
        <Tag color={schema === 'SRT' ? 'blue' : 'orange'}>
          {schema}
        </Tag>
      ),
    },
    {
      title: 'Addr',
      key: 'addr',
      render: (_, record) => {
        const srtModeTag =
          record.schema === 'SRT' ? renderSrtModeTag(getEndpointValue(record, 'mode')) : null;

        return (
          <Space size="small">
            {renderProtocolTag(record.schema)}
            {srtModeTag}
            <span>{getEndpointAddress(record)}</span>
          </Space>
        );
      },
      sorter: (a, b) => getEndpointAddress(a).localeCompare(getEndpointAddress(b)),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => {
        const items = [
          {
            key: 'edit',
            icon: <EditOutlined />,
            label: 'Edit',
          },
          ...(record.rowType === 'destination'
            ? [{
                key: 'delete',
                icon: <DeleteOutlined />,
                label: routeBusy ? (
                  <AntTooltip title={deleteDisabledMessage}>
                    <span>Delete</span>
                  </AntTooltip>
                ) : 'Delete',
                danger: true,
                disabled: routeBusy,
              }]
            : []),
        ];

        const handleMenuClick = ({ key }) => {
          if (key === 'edit') {
            navigate(record.rowType === 'source' ? `/routes/${id}/edit` : `/routes/${id}/destinations/${record.endpointId}/edit`);
            return;
          }

          if (key === 'delete') {
            handleDeleteDestination(record);
          }
        };

        return (
          <Dropdown
            menu={{
              items,
              onClick: handleMenuClick,
            }}
            trigger={['click']}
          >
            <Button
              icon={<HolderOutlined />}
              aria-label={`Actions for ${record.name}`}
            />
          </Dropdown>
        );
      },
    },
  ];

  // Delete destination handler
  const handleDeleteDestination = (record) => {
    modal.confirm({
      title: 'Are you sure you want to delete this destination?',
      icon: <ExclamationCircleFilled />,
      content: `Destination: ${record.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteDestination(record.id);
      },
    });
  };

  // Delete destination API call
  const deleteDestination = async (destId) => {
    try {
      await destinationsApi.delete(id, destId);
      messageApi.success('Destination deleted successfully');
      fetchRouteData(); // Refresh the data
    } catch (error) {
      messageApi.error(`Failed to delete destination: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const RouteStatisticsTab = () => {
    if (!stats || !statsHistory.length) {
      return (
        <Card title="Statistics" style={{ marginBottom: 24 }}>
          <div style={{ textAlign: 'center', padding: '20px' }}>
            <Text type="secondary">Waiting for statistics...</Text>
          </div>
        </Card>
      );
    }

    const formatBytes = (bytes) => {
      if (bytes === 0) return '0 B';
      const k = 1024;
      const sizes = ['B', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    };

    const pickFirstNumber = (obj, keys) => {
      if (!obj) return null;
      for (const k of keys) {
        const v = obj?.[k];
        if (typeof v === 'number') return v;
      }
      return null;
    };

    const rttKeys = ['rtt', 'rtt-ms', 'rtt_ms', 'srtt', 'srtt-ms', 'srtt_ms'];
    const lossKeys = [
      'pkt-recv-loss',
      'pkt_recv_loss',
      'packets-recv-lost',
      'packets_recv_lost',
      'pkt-snd-loss',
      'pkt_snd_loss',
    ];
    const retransKeys = ['pkt-retrans', 'pkt_retrans', 'retrans', 'retransmissions'];

    const sourceSrt = stats?.source?.srt;
    const sourceRtt = pickFirstNumber(sourceSrt, rttKeys);
    const sourceLoss = pickFirstNumber(sourceSrt, lossKeys);
    const sourceRetrans = pickFirstNumber(sourceSrt, retransKeys);

    const latestDestStats = Array.isArray(stats?.destinations) ? stats.destinations : [];
    const latestDestById = latestDestStats.reduce((acc, d) => {
      if (d?.id) acc[d.id] = d;
      return acc;
    }, {});

    const destinationStatsColumns = [
      {
        title: 'Name',
        dataIndex: 'name',
        key: 'name',
        render: (text, record) => (
          <Space>
            <a href={`#/routes/${id}/destinations/${record.id}/edit`}>{text}</a>
          </Space>
        ),
      },
      {
        title: 'Schema',
        dataIndex: 'schema',
        key: 'schema',
        render: (schema) => (
          <Tag color={schema === 'SRT' ? 'blue' : schema === 'UDP' ? 'orange' : 'default'}>
            {schema || 'N/A'}
          </Tag>
        ),
      },
      {
        title: 'Type',
        key: 'type',
        render: (_, record) => {
          const live = latestDestById[record.id];
          return live?.type || 'N/A';
        },
      },
      {
        title: 'Live Bitrate',
        key: 'live_bitrate',
        render: (_, record) => {
          const live = latestDestById[record.id];
          const bps =
            typeof live?.bytes_out_per_sec === 'number' ? Math.round(live.bytes_out_per_sec * 8) : null;
          return bps != null ? `${bps} bps` : 'N/A';
        },
      },
      {
        title: 'Total Bytes',
        key: 'total_bytes',
        render: (_, record) => {
          const live = latestDestById[record.id];
          return typeof live?.bytes_out_total === 'number' ? formatBytes(live.bytes_out_total) : 'N/A';
        },
      },
    ];

    return (
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Card title="Source" style={{ marginBottom: 0 }}>
          <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
            <Col xs={24} sm={12} md={8}>
              <Card type="inner" title="RTT (if available)">
                <Statistic value={sourceRtt != null ? sourceRtt : null} />
                <Text type="secondary">Field name depends on SRT plugin</Text>
              </Card>
            </Col>
            <Col xs={24} sm={12} md={8}>
              <Card type="inner" title="Loss (if available)">
                <Statistic value={sourceLoss != null ? sourceLoss : null} />
                <Text type="secondary">May be packets or %</Text>
              </Card>
            </Col>
            <Col xs={24} sm={12} md={8}>
              <Card type="inner" title="Retrans (if available)">
                <Statistic value={sourceRetrans != null ? sourceRetrans : null} />
                <Text type="secondary">May be packets or rate</Text>
              </Card>
            </Col>
          </Row>

          <Card type="inner" title="Source Throughput (bytes/sec)">
            <ResponsiveContainer width="100%" height={250}>
              <AreaChart data={statsHistory}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="timestamp" interval="preserveStartEnd" minTickGap={50} />
                <YAxis
                  tickFormatter={(value) => formatBytes(value)}
                  domain={['auto', 'auto']}
                  padding={{ top: 20 }}
                />
                <Tooltip formatter={(value) => formatBytes(value)} />
                <Area
                  type="monotone"
                  dataKey="source.bytes_in_per_sec"
                  stroke="#8884d8"
                  fill="#8884d8"
                  name="Bytes / sec"
                  isAnimationActive={false}
                  dot={false}
                />
              </AreaChart>
            </ResponsiveContainer>
          </Card>
        </Card>

        <Card title="Destinations">
          <Table
            columns={destinationStatsColumns}
            dataSource={filteredDestinations}
            rowKey="id"
            pagination={{ defaultPageSize: 10, showSizeChanger: true }}
            scroll={{ x: true }}
            expandable={{
              expandedRowRender: (record) => {
                const data = statsHistory.map((p) => {
                  const dests = Array.isArray(p?.destinations) ? p.destinations : [];
                  const live = dests.find((d) => d?.id === record.id);
                  const bytesPerSec = typeof live?.bytes_out_per_sec === 'number' ? live.bytes_out_per_sec : null;
                  return {
                    timestamp: p.timestamp,
                    bytes_out_per_sec: bytesPerSec,
                  };
                });

                const latest = latestDestById[record.id];
                const destSrt = latest?.srt;
                const destRtt = pickFirstNumber(destSrt, rttKeys);
                const destLoss = pickFirstNumber(destSrt, lossKeys);

                return (
                  <Space direction="vertical" size="middle" style={{ width: '100%' }}>
                    <Card size="small" title="Throughput (bytes/sec)">
                      <ResponsiveContainer width="100%" height={200}>
                        <LineChart data={data}>
                          <CartesianGrid strokeDasharray="3 3" />
                          <XAxis dataKey="timestamp" interval="preserveStartEnd" minTickGap={50} />
                          <YAxis tickFormatter={(value) => formatBytes(value)} />
                          <Tooltip formatter={(value) => formatBytes(value)} />
                          <Line
                            type="monotone"
                            dataKey="bytes_out_per_sec"
                            stroke="#82ca9d"
                            name="Bytes / sec"
                            isAnimationActive={false}
                            dot={false}
                          />
                        </LineChart>
                      </ResponsiveContainer>
                    </Card>

                    {record.schema === 'SRT' && (
                      <Collapse
                        items={[
                          {
                            key: 'srt',
                            label: 'SRT QoS (if available)',
                            children: (
                              <Row gutter={[16, 16]}>
                                <Col xs={24} sm={12} md={8}>
                                  <Card size="small" title="RTT">
                                    <Statistic value={destRtt != null ? destRtt : null} />
                                  </Card>
                                </Col>
                                <Col xs={24} sm={12} md={8}>
                                  <Card size="small" title="Loss">
                                    <Statistic value={destLoss != null ? destLoss : null} />
                                  </Card>
                                </Col>
                                <Col xs={24} sm={12} md={8}>
                                  <Card size="small" title="SRT fields">
                                    <Statistic value={destSrt ? Object.keys(destSrt).length : 0} />
                                  </Card>
                                </Col>
                              </Row>
                            ),
                          },
                        ]}
                      />
                    )}
                  </Space>
                );
              },
              rowExpandable: (record) => true,
            }}
          />
        </Card>
      </Space>
    );
  };

  if (loading || !routeData) {
    return (
      <div style={{ padding: '24px' }}>
        <Card loading={true} />
      </div>
    );
  }

  // Get status details
  const statusDetails = getStatusDetails(routeData);
  const runtimeStatus = routeData?.schema_status || routeData?.status;
  const runtimeStatusMeta = getRuntimeStatusMeta(runtimeStatus);

  // Route status toggle handler
  const handleRouteStatusToggle = async () => {
    try {
      if (routeBusy) {
        setPendingAction('stop');
        setRouteData((prev) => prev ? { ...prev, schema_status: 'stopping' } : prev);
        await routesApi.stop(id);
        const settled = await refreshRouteUntilStable('stop');
        messageApi.success('Route stopped successfully');
        if (settled === false) {
          messageApi.warning('Route is still stopping. Refresh in a moment if it does not update.');
        }
      } else {
        setPendingAction('start');
        setRouteData((prev) => prev ? { ...prev, schema_status: 'starting' } : prev);
        await routesApi.start(id);
        const settled = await refreshRouteUntilStable('start');
        messageApi.success('Route started successfully');
        if (settled === false) {
          messageApi.warning('Route is still starting. Refresh in a moment if it does not update.');
        }
      }
    } catch (error) {
      // Handle specific error cases
      if (error.message && error.message.includes('already_started')) {
        messageApi.info('Route is already started');

        // Update the UI to reflect that the route is started
        setRouteData(prev => ({
          ...prev,
          status: 'started',
          schema_status: null
        }));
      } else if (error.message && error.message.includes('not_found')) {
        messageApi.info('Route process not found. It may have already been stopped.');
        await fetchRouteData();
      } else if (error.response && error.response.status === 422) {
        // Handle 422 Unprocessable Entity error
        messageApi.error('Invalid request. The server could not process the request.');

        // Keep the current state
        console.error('422 Error:', error);
      } else {
        const action = routeBusy ? 'stop' : 'start';
        messageApi.error(`Failed to ${action} route: ${error.message}`);
      }
      console.error('Error:', error);
    } finally {
      setPendingAction(null);
    }
  };

  // Route deletion handler
  const handleRouteDelete = () => {
    modal.confirm({
      title: 'Are you sure you want to delete this route?',
      icon: <ExclamationCircleFilled />,
      content: `Route: ${routeData.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteRoute();
      },
    });
  };

  // Delete route API call
  const deleteRoute = async () => {
    try {
      await routesApi.delete(id);
      messageApi.success('Route deleted successfully');
      navigate('/routes');
    } catch (error) {
      messageApi.error(`Failed to delete route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  return (
    <Space
      direction="vertical"
      size="large"
      style={{ width: '100%', maxWidth: 1200, margin: '0 auto' }}
    >
      {contextHolder}
      {modalContextHolder}

      <Row justify="space-between" align="middle" gutter={[16, 16]}>
        <Col flex="auto">
          <Space direction="vertical" size="small" style={{ width: '100%' }}>
            <Space align="center" size="middle" wrap>
              <Button
                icon={<ArrowLeftOutlined />}
                onClick={() => navigate(ROUTES.ROUTES)}
              >
                Back
              </Button>
              <Title level={3} style={{ margin: 0, fontSize: '1.75rem', fontWeight: 600 }}>
                {routeData.name}
              </Title>
            </Space>

            <Space size="small" wrap>
              <Tag color={runtimeStatusMeta.color}>
                {formatStatusLabel(runtimeStatus)}
              </Tag>
              {routeData?.status && routeData?.schema_status && routeData.status !== routeData.schema_status && (
                <Tag color={statusDetails.color}>
                  Route {formatStatusLabel(routeData.status)}
                </Tag>
              )}
              <Text type="secondary">
                Last Updated: {new Date(routeData.updated_at).toLocaleString()}
              </Text>
            </Space>
          </Space>
        </Col>

        <Col>
          <Space wrap>
            <Button
              type={statusDetails.buttonType}
              icon={statusDetails.buttonIcon}
              onClick={handleRouteStatusToggle}
              loading={pendingAction != null}
              disabled={pendingAction != null}
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                minWidth: '80px'
              }}
            >
              {statusDetails.buttonText}
            </Button>
            <AntTooltip title={routeBusy ? deleteDisabledMessage : null}>
              <Button
                danger
                type="primary"
                icon={<DeleteOutlined />}
                onClick={handleRouteDelete}
                disabled={routeBusy || pendingAction != null}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                Delete
              </Button>
            </AntTooltip>
          </Space>
        </Col>
      </Row>

      <Tabs
        activeKey={activeStatsTab}
        onChange={setActiveStatsTab}
        items={[
          {
            key: 'overview',
            label: 'Overview',
            children: null
          },
          {
            key: 'statistics',
            label: 'Statistics',
            children: (
              <RouteStatisticsTab />
            )
          }
        ]}
      />

      <Card
        title="Endpoints"
        extra={
          <Button
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => navigate(`/routes/${id}/destinations/new/edit`)}
          >
            Add Destination
          </Button>
        }
      >
        <Input
          prefix={<SearchOutlined />}
          placeholder="Filter endpoints by name or address"
          style={{ marginBottom: 16, width: '100%' }}
          value={destinationFilter}
          onChange={(e) => setDestinationFilter(e.target.value)}
        />
        <Table
          columns={endpointColumns}
          dataSource={endpointsData}
          rowKey="id"
          pagination={{
            defaultPageSize: 10,
            showSizeChanger: true,
            showTotal: (total) => `Total ${total} endpoints`,
          }}
          scroll={{ x: true }}
          rowClassName={(record) => (record.rowType === 'source' ? 'route-endpoint-source-row' : '')}
        />
      </Card>
    </Space>
  );
};

export default RouteItem;
