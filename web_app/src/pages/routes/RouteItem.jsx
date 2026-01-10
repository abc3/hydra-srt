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
  Descriptions,
  Collapse,
  message,
  Input,
  Tabs,
  Statistic
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
  SearchOutlined
} from '@ant-design/icons';
import { useParams, useNavigate } from 'react-router-dom';
import { routesApi, destinationsApi } from '../../utils/api';
import { Socket } from "phoenix";
import { API_BASE_URL } from "../../utils/constants";
import { getToken } from "../../utils/auth";
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
  }, [id, messageApi]);

  // Breadcrumb setup
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        },
        {
          href: '/routes',
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
      setRouteData(result.data);
      console.log("Route data:", result.data);
    } catch (error) {
      messageApi.error(`Failed to fetch route data: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
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

  // Destination table columns
  const destinationColumns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => a.name.localeCompare(b.name),
      render: (text, record) => (
        <Space>
          <a href={`#/routes/${id}/destinations/${record.id}/edit`}>
            {text}
          </a>
          {/* <Tag color={record.enabled ? 'green' : 'red'}>
            {record.enabled ? 'Active' : 'Inactive'}
          </Tag> */}
        </Space>
      ),
    },
    {
      title: 'Schema',
      dataIndex: 'schema',
      key: 'schema',
      filters: [
        { text: 'SRT', value: 'SRT' },
        { text: 'Other', value: 'Other' }
      ],
      onFilter: (value, record) => record.schema === value,
      render: (schema) => (
        <Tag color={schema === 'SRT' ? 'blue' : 'orange'}>
          {schema}
        </Tag>
      ),
    },
    // {
    //   title: 'Authentication',
    //   key: 'authentication',
    //   filters: [
    //     { text: 'Enabled', value: true },
    //     { text: 'Disabled', value: false }
    //   ],
    //   onFilter: (value, record) => {
    //     if (record.schema !== 'SRT') return !value;
    //     return (record.schema_options && record.schema_options.authentication) === value;
    //   },
    //   render: (_, record) => {
    //     if (record.schema !== 'SRT') return <Tag color="default">N/A</Tag>;
    //     return record.schema_options && record.schema_options.authentication ? (
    //       <Tag color="green">Enabled</Tag>
    //     ) : (
    //       <Tag color="red">Disabled</Tag>
    //     );
    //   },
    // },
    {
      title: 'Destination',
      key: 'host_port',
      render: (_, record) => {
        console.log(record);
        switch (record.schema) {
          case 'SRT':
            return (`${record.schema_options?.localaddress}:${record.schema_options?.localport}:${record.schema_options?.mode}`)
          case 'UDP':
            return (`${record.schema_options?.host}:${record.schema_options?.port}`)
          default:
            return 'N/A'
        }
      },
      sorter: (a, b) => a.port - b.port,
    },
    {
      title: 'Latency',
      dataIndex: 'latency',
      key: 'latency',
      render: (latency) => latency ? `${latency}ms` : 'N/A',
      sorter: (a, b) => {
        if (!a.latency) return 1;
        if (!b.latency) return -1;
        return a.latency - b.latency;
      },
    },
    {
      title: 'Last Updated',
      dataIndex: 'updated_at',
      key: 'updated_at',
      render: (date) => new Date(date).toLocaleString(),
      sorter: (a, b) => new Date(a.updated_at) - new Date(b.updated_at),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => (
        <Space>
          <Button
            type="link"
            icon={<EditOutlined />}
            aria-label={`Edit destination ${record.name}`}
            onClick={() => navigate(`/routes/${id}/destinations/${record.id}/edit`)}
          >
            Edit
          </Button>
          <Button
            type="link"
            danger
            icon={<DeleteOutlined />}
            aria-label={`Delete destination ${record.name}`}
            onClick={() => handleDeleteDestination(record)}
          >
            Delete
          </Button>
        </Space>
      ),
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

  const SrtSourceStats = () => {
    if (!stats || !statsHistory.length) {
      return (
        <Card title="Route Statistics (Overview)" style={{ marginBottom: 24 }}>
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

    const getSourceBytesPerSec = (s) => {
      const v = s?.source?.bytes_in_per_sec;
      return typeof v === 'number' ? v : null;
    };

    const getDestinations = (s) => {
      return Array.isArray(s?.destinations) ? s.destinations : [];
    };

    const getWorstDestBytesPerSec = (s) => {
      const dests = getDestinations(s);
      if (!dests.length) return null;

      const rates = dests
        .map(d => (typeof d?.bytes_out_per_sec === 'number' ? d.bytes_out_per_sec : null))
        .filter(v => typeof v === 'number');
      if (!rates.length) return null;

      return Math.min(...rates);
    };

    const sourceBytesPerSec = getSourceBytesPerSec(stats);
    const worstDestBytesPerSec = getWorstDestBytesPerSec(stats);

    return (
      <Card title="Route Statistics (Overview)" style={{ marginBottom: 24 }}>
        <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
          <Col xs={24} sm={12} md={8}>
            <Card type="inner" title="Source Bitrate">
              <div data-testid="kpi-source-bitrate">
                <Statistic
                  value={sourceBytesPerSec != null ? (sourceBytesPerSec * 8) : null}
                  precision={0}
                  suffix="bps"
                />
              </div>
              <Text type="secondary">From pipeline byte counter</Text>
            </Card>
          </Col>
          <Col xs={24} sm={12} md={8}>
            <Card type="inner" title="Connected Callers">
              <div data-testid="kpi-connected-callers">
                <Statistic value={stats['connected-callers'] ?? 0} />
              </div>
              <Text type="secondary">SRT source only</Text>
            </Card>
          </Col>
          <Col xs={24} sm={12} md={8}>
            <Card type="inner" title="Worst Destination Bitrate">
              <div data-testid="kpi-worst-dest-bitrate">
                <Statistic
                  value={worstDestBytesPerSec != null ? (worstDestBytesPerSec * 8) : null}
                  precision={0}
                  suffix="bps"
                />
              </div>
              <Text type="secondary">Lowest bytes/sec across destinations</Text>
            </Card>
          </Col>
        </Row>

        <Row gutter={[16, 16]}>
          {/* <Col span={24}>
            <Card type="inner" title="Connected Callers">
              <Row justify="space-between" align="middle">
                <Col>
                  <Title level={3} style={{ margin: 0 }}>
                    {stats['connected-callers']}
                  </Title>
                  <Text type="secondary">Current Connections</Text>
                </Col>
              </Row>
            </Card>
          </Col> */}
          
          <Col span={12}>
            <Card type="inner" title="Source Throughput (bytes/sec)">
              <ResponsiveContainer width="100%" height={250}>
                <AreaChart data={statsHistory}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis 
                    dataKey="timestamp"
                    interval="preserveStartEnd"
                    minTickGap={50}
                  />
                  <YAxis 
                    tickFormatter={(value) => formatBytes(value)}
                    domain={['auto', 'auto']}
                    padding={{ top: 20 }}
                  />
                  <Tooltip 
                    formatter={(value) => formatBytes(value)}
                  />
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
          </Col>

          <Col span={12}>
            <Card type="inner" title="Connected Callers">
              <ResponsiveContainer width="100%" height={250}>
                <AreaChart data={statsHistory}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis 
                    dataKey="timestamp"
                    interval="preserveStartEnd"
                    minTickGap={50}
                  />
                  <YAxis 
                    domain={['auto', 'auto']}
                    padding={{ top: 20 }}
                  />
                  <Tooltip />
                  <Area 
                    type="monotone" 
                    dataKey="connected-callers" 
                    stroke="#82ca9d" 
                    fill="#82ca9d" 
                    name="Connected Callers"
                    isAnimationActive={false}
                    dot={false}
                  />
                </AreaChart>
              </ResponsiveContainer>
            </Card>
          </Col>
        </Row>
      </Card>
    );
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

  // Helper function to check if route is started
  const isRouteStarted = routeData && routeData.status && routeData.status.toLowerCase() === 'started';

  // Route status toggle handler
  const handleRouteStatusToggle = async () => {
    try {
      let result;
      if (routeData.status && routeData.status.toLowerCase() === 'started') {
        // If the route is started, stop it
        result = await routesApi.stop(id);

        // Only update if result has data
        if (result && result.data) {
          setRouteData(prev => ({
            ...prev,
            status: result.data.status
          }));
        } else {
          // If no data is returned, assume the route is stopped
          setRouteData(prev => ({
            ...prev,
            status: 'stopped'
          }));
        }

        messageApi.success('Route stopped successfully');
      } else {
        // If the route is not started, start it
        result = await routesApi.start(id);

        // Only update if result has data
        if (result && result.data) {
          setRouteData(prev => ({
            ...prev,
            status: result.data.status
          }));
        } else {
          // If no data is returned, assume the route is started
          setRouteData(prev => ({
            ...prev,
            status: 'started'
          }));
        }

        messageApi.success('Route started successfully');
      }
    } catch (error) {
      // Handle specific error cases
      if (error.message && error.message.includes('already_started')) {
        messageApi.info('Route is already started');

        // Update the UI to reflect that the route is started
        setRouteData(prev => ({
          ...prev,
          status: 'started'
        }));
      } else if (error.message && error.message.includes('not_found')) {
        messageApi.info('Route process not found. It may have already been stopped.');

        // Update the UI to reflect that the route is stopped
        setRouteData(prev => ({
          ...prev,
          status: 'stopped'
        }));
      } else if (error.response && error.response.status === 422) {
        // Handle 422 Unprocessable Entity error
        messageApi.error('Invalid request. The server could not process the request.');

        // Keep the current state
        console.error('422 Error:', error);
      } else {
        const action = isRouteStarted ? 'stop' : 'start';
        messageApi.error(`Failed to ${action} route: ${error.message}`);
      }
      console.error('Error:', error);
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

  // Filter destinations
  const filteredDestinations = routeData?.destinations.filter(dest =>
    dest.name.toLowerCase().includes(destinationFilter.toLowerCase()) ||
    (dest.host && dest.host.toLowerCase().includes(destinationFilter.toLowerCase()))
  ) || [];

  return (
    <Space
      direction="vertical"
      size="large"
      style={{
        width: '100%',
        padding: '0 24px',
        '@media(maxWidth: 768px)': {
          padding: '0 12px'
        }
      }}
    >
      {contextHolder}
      {modalContextHolder}

      {/* Route Info Card */}
      <Card style={{ marginBottom: 24 }}>
        <Row justify="space-between" align="middle">
          <Col>
            <Space direction="vertical" size="small">
              <Title level={4} style={{ margin: 0 }}>{routeData.name}</Title>
              <Space>
                <Tag color={statusDetails.color}>
                  {routeData.status ? routeData.status.charAt(0).toUpperCase() + routeData.status.slice(1) : 'Unknown'}
                </Tag>
                <Text type="secondary">
                  Last Updated: {new Date(routeData.updated_at).toLocaleString()}
                </Text>
              </Space>
            </Space>
          </Col>
          <Col>
            <Space>
              <Button
                type={statusDetails.buttonType}
                icon={statusDetails.buttonIcon}
                onClick={handleRouteStatusToggle}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                {statusDetails.buttonText}
              </Button>
              <Button
                danger
                type="primary"
                icon={<DeleteOutlined />}
                onClick={handleRouteDelete}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                Delete
              </Button>
            </Space>
          </Col>
        </Row>
      </Card>

      <Tabs
        activeKey={activeStatsTab}
        onChange={setActiveStatsTab}
        items={[
          {
            key: 'overview',
            label: 'Overview',
            children: (
              <>
                {/* SRT Statistics */}
                <SrtSourceStats />
              </>
            )
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

      {/* Source Details */}
      <Card
        title="Source Configuration"
        style={{ marginBottom: 24 }}
        extra={
          <Button
            onClick={() => navigate(`/routes/${id}/edit`)}
            icon={<EditOutlined />}
          >
            Edit
          </Button>
        }
      >
        <Descriptions
          column={2}
          bordered
          styles={{ content: { textAlign: 'left' } }}
        >
          <Descriptions.Item label="Source">
            <Tag color={routeData.schema === 'SRT' ? 'blue' : 'orange'}>
              {routeData.schema}
            </Tag>
            {' '}
            {routeData.schema === 'SRT' ? 
              `${routeData.schema_options?.localaddress || 'N/A'}:${routeData.schema_options?.localport || 'N/A'}:${routeData.schema_options?.mode || 'N/A'}` :
              routeData.schema === 'UDP' ?
              `${routeData.schema_options?.address || 'N/A'}:${routeData.schema_options?.port || 'N/A'}` :
              'N/A'
            }
          </Descriptions.Item>
          <Descriptions.Item label="Node">{routeData.node}</Descriptions.Item>
          
          {routeData.schema === 'SRT' && (
            <>
              <Descriptions.Item label="Latency">{routeData.schema_options?.latency ? `${routeData.schema_options.latency}ms` : 'Default (125ms)'}</Descriptions.Item>
              <Descriptions.Item label="Auto Reconnect">
                <Tag color={routeData.schema_options?.['auto-reconnect'] ? 'green' : 'red'}>
                  {routeData.schema_options?.['auto-reconnect'] ? 'Enabled' : 'Disabled'}
                </Tag>
              </Descriptions.Item>
              <Descriptions.Item label="Keep Listening">
                <Tag color={routeData.schema_options?.['keep-listening'] ? 'green' : 'red'}>
                  {routeData.schema_options?.['keep-listening'] ? 'Enabled' : 'Disabled'}
                </Tag>
              </Descriptions.Item>
              <Descriptions.Item label="Authentication">
                <Tag color={routeData.schema_options?.authentication ? 'green' : 'red'}>
                  {routeData.schema_options?.authentication ? 'Enabled' : 'Disabled'}
                </Tag>
              </Descriptions.Item>
              {routeData.schema_options?.authentication && (
                <Descriptions.Item label="Key Length">
                  {routeData.schema_options?.pbkeylen !== undefined ? routeData.schema_options.pbkeylen : '0 (Default)'}
                </Descriptions.Item>
              )}
            </>
          )}
          
          {routeData.schema === 'UDP' && (
            <>
              <Descriptions.Item label="Address">{routeData.schema_options?.address || '0.0.0.0 (Default)'}</Descriptions.Item>
              <Descriptions.Item label="Port">{routeData.schema_options?.port || 'N/A'}</Descriptions.Item>
              <Descriptions.Item label="Buffer Size">{routeData.schema_options?.['buffer-size'] ? `${routeData.schema_options['buffer-size']} bytes` : '0 bytes (Default)'}</Descriptions.Item>
              <Descriptions.Item label="MTU">{routeData.schema_options?.mtu || '1492 (Default)'}</Descriptions.Item>
            </>
          )}
          
          <Descriptions.Item label="Enabled">
            <Tag color={routeData.enabled ? 'green' : 'red'}>
              {routeData.enabled ? 'Yes' : 'No'}
            </Tag>
          </Descriptions.Item>
          <Descriptions.Item label="Export Stats">
            <Tag color={(routeData.exportStats || routeData.export_stats) ? 'green' : 'red'}>
              {(routeData.exportStats || routeData.export_stats) ? 'Yes' : 'No'}
            </Tag>
            {(routeData.exportStats || routeData.export_stats) && <span style={{marginLeft: '8px'}}></span>}
          </Descriptions.Item>
          {routeData.gstDebug && (
            <Descriptions.Item label="GST_DEBUG" span={2}>
              {routeData.gstDebug}
            </Descriptions.Item>
          )}
        </Descriptions>
      </Card>

      {/* Destinations Table */}
      <Card
        title="Destinations"
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
          placeholder="Filter destinations by name or host"
          style={{ marginBottom: 16, width: '100%' }}
          value={destinationFilter}
          onChange={(e) => setDestinationFilter(e.target.value)}
        />
        <Table
          columns={destinationColumns}
          dataSource={filteredDestinations}
          rowKey="id"
          pagination={{
            defaultPageSize: 10,
            showSizeChanger: true,
            showTotal: (total) => `Total ${total} destinations`,
          }}
          scroll={{ x: true }}  // Enable horizontal scrolling on small screens
          expandable={{
            expandedRowRender: record => {
              if (record.schema !== 'SRT' || !record.schema_options || !record.schema_options.authentication) {
                return null;
              }

              return (
                <Card size="small" title="Authentication Details" style={{ margin: '0 16px' }}>
                  <Descriptions column={2} size="small">
                    <Descriptions.Item label="Authentication">
                      <Tag color="green">Enabled</Tag>
                    </Descriptions.Item>
                    <Descriptions.Item label="Key Length">
                      {record.schema_options.pbkeylen || '0 (Default)'}
                    </Descriptions.Item>
                  </Descriptions>
                </Card>
              );
            },
            rowExpandable: record => record.schema === 'SRT' && record.schema_options && record.schema_options.authentication,
          }}
        />
      </Card>
    </Space>
  );
};

export default RouteItem;
