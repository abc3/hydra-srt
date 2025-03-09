import React, { useEffect, useState } from 'react';
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

const { Title, Text } = Typography;

const RouteItem = () => {
  const navigate = useNavigate();
  const { id } = useParams();
  const [routeData, setRouteData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const [destinationFilter, setDestinationFilter] = useState('');

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
          {text}
          <Tag color={record.enabled ? 'green' : 'red'}>
            {record.enabled ? 'Active' : 'Inactive'}
          </Tag>
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
    {
      title: 'Authentication',
      key: 'authentication',
      filters: [
        { text: 'Enabled', value: true },
        { text: 'Disabled', value: false }
      ],
      onFilter: (value, record) => {
        if (record.schema !== 'SRT') return !value;
        return (record.schema_options && record.schema_options.authentication) === value;
      },
      render: (_, record) => {
        if (record.schema !== 'SRT') return <Tag color="default">N/A</Tag>;
        return record.schema_options && record.schema_options.authentication ? (
          <Tag color="green">Enabled</Tag>
        ) : (
          <Tag color="red">Disabled</Tag>
        );
      },
    },
    {
      title: 'Host:Port',
      key: 'host_port',
      render: (_, record) => record.host ? `${record.host}:${record.port}` : `Port: ${record.port}`,
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
          <Descriptions.Item label="Schema">
            <Tag color={routeData.schema === 'SRT' ? 'blue' : 'orange'}>
              {routeData.schema}
            </Tag>
          </Descriptions.Item>
          <Descriptions.Item label="Node">{routeData.node}</Descriptions.Item>
          <Descriptions.Item label="Port">{routeData.port}</Descriptions.Item>
          <Descriptions.Item label="SRT Mode">{routeData.srtMode}</Descriptions.Item>
          <Descriptions.Item label="Auto Reconnect">
            {routeData["auto-reconnect"] ? 'Yes' : 'No'}
          </Descriptions.Item>
          <Descriptions.Item label="Authentication">
            {routeData.schema === 'SRT' && routeData.schema_options && routeData.schema_options.authentication ? (
              <Tag color="green">Enabled</Tag>
            ) : (
              <Tag color="red">Disabled</Tag>
            )}
          </Descriptions.Item>
          {routeData.schema === 'SRT' && routeData.schema_options && routeData.schema_options.authentication && (
            <Descriptions.Item label="Key Length">
              {routeData.schema_options.pbkeylen || '0 (Default)'}
            </Descriptions.Item>
          )}
        </Descriptions>
      </Card>

      {/* Advanced Settings */}
      <Collapse 
        ghost 
        defaultActiveKey={[]} 
        style={{ marginBottom: 24 }}
        items={[
          {
            key: 'advanced',
            label: 'Advanced Settings',
            children: (
              <Descriptions 
                column={2} 
                bordered 
                styles={{ content: { textAlign: 'left' } }}
              >
                <Descriptions.Item label="Export Stats">
                  {routeData.exportStats ? 'Yes' : 'No'}
                </Descriptions.Item>
                <Descriptions.Item label="Keep Listening">
                  {routeData["keep-listening"] ? 'Yes' : 'No'}
                </Descriptions.Item>
                {routeData.schema === 'SRT' && routeData.schema_options && routeData.schema_options.authentication && (
                  <>
                    <Descriptions.Item label="Authentication" span={2}>
                      <Space direction="vertical">
                        <Tag color="green">Enabled</Tag>
                        <Text>Key Length: {routeData.schema_options.pbkeylen || '0 (Default)'}</Text>
                      </Space>
                    </Descriptions.Item>
                  </>
                )}
              </Descriptions>
            )
          }
        ]}
      />

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
