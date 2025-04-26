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
  Input
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

// Create socket instance
const socket = new Socket(`${API_BASE_URL}/socket`, {
  params: { token: getToken()?.replace('Bearer ', '') }
});

// Connect to the socket
socket.connect();

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

  // Phoenix Channel connection
  useEffect(() => {
    if (!id) return;

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
      setStatsHistory(prev => [...prev, { ...stats, timestamp }]);
    });

    // Cleanup on component unmount
    return () => {
      channel.off("stats");
      channel.leave();
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
        <Card title="SRT Source Statistics" style={{ marginBottom: 24 }}>
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

    return (
      <Card title="SRT Source Statistics" style={{ marginBottom: 24 }}>
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
            <Card type="inner" title="Total Bytes Received">
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
                    dataKey="total-bytes-received" 
                    stroke="#8884d8" 
                    fill="#8884d8" 
                    name="Bytes Received"
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

      {/* SRT Statistics */}
      <SrtSourceStats />

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
