import { Form, Input, Radio, Card, Space, InputNumber, Switch, Select, Button, Row, Col, message, Typography } from 'antd';
import { InfoCircleOutlined, SaveOutlined, CloseOutlined, HomeOutlined, LoadingOutlined } from '@ant-design/icons';
import PropTypes from 'prop-types';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useState, useRef } from 'react';
import { routesApi } from '../../utils/api';
import React from 'react';

const { Title } = Typography;

const RouteSourceEdit = ({ initialValues, onChange }) => {
  const [form] = Form.useForm();
  const navigate = useNavigate();
  const { id } = useParams();
  const [messageApi, contextHolder] = message.useMessage();
  const [loading, setLoading] = useState(id !== 'new');
  const dataFetchedRef = useRef(false);
  const [routeData, setRouteData] = useState(null);

  // Set breadcrumb items for the RouteSourceEdit page
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
        ...(id !== 'new' ? [
          {
            href: `/routes/${id}`,
            title: loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
          }
        ] : []),
        {
          title: id === 'new' ? 'New Route' : 'Edit Route',
        }
      ]);
    }
  }, [id, routeData, loading]);

  // Fetch existing route data when component mounts
  useEffect(() => {
    if (id !== 'new' && !dataFetchedRef.current) {
      dataFetchedRef.current = true;

      routesApi.getById(id)
        .then(result => {
          setRouteData(result.data);
          form.setFieldsValue(result.data);
          setLoading(false);
        })
        .catch(error => {
          messageApi.error(`Failed to fetch route data: ${error.message}`);
          console.error('Error:', error);
          setLoading(false);
        });
    }
  }, [id, form, messageApi]);

  const availableNodes = [
    { label: 'self', value: 'self' }
  ];

  const handleValuesChange = (changedValues, allValues) => {
    if (onChange) {
      onChange(allValues);
    }
  };

  const handleSave = () => {
    form.validateFields()
      .then(values => {
        const loadingMessage = messageApi.loading('Saving route...', 0);

        // Determine if we're creating or updating
        const savePromise = id === 'new'
          ? routesApi.create(values)
          : routesApi.update(id, values);

        savePromise
          .then(data => {
            loadingMessage();
            messageApi.success('Route saved successfully');
            if (data) {
              form.setFieldsValue(data.data);
              // If this is a new route, navigate to the route detail page
              if (id === 'new' && data.data.id) {
                navigate(`/routes/${data.data.id}`);
              }
            }
          })
          .catch(error => {
            loadingMessage();
            messageApi.error(`Failed to save route: ${error.message}`);
            console.error('Error:', error);
          });
      })
      .catch(info => {
        messageApi.error('Please check the form for errors');
        console.log('Validate Failed:', info);
      });
  };

  const handleCancel = () => {
    navigate(id === 'new' ? '/routes' : `/routes/${id}`);
  };

  return (
    <div>
      {contextHolder}

      <Title
        level={3}
        style={{
          margin: '0 0 24px 0',
          fontSize: '1.75rem',
          fontWeight: 600
        }}
      >
        {id === 'new' ? 'Add Source' : 'Edit Source'}
      </Title>

      {id === 'new' && (
        <Card 
          style={{ marginBottom: '24px', backgroundColor: '#141414', border: '1px solid #303030' }}
          size="small"
        >
          <Space align="start">
            <InfoCircleOutlined style={{ color: '#1890ff', fontSize: '16px', marginTop: '3px' }} />
            <Typography.Text type="secondary">
              Destination creation will be available after saving this source. Please save the source first to continue setting up your route.
            </Typography.Text>
          </Space>
        </Card>
      )}

      <Form
        form={form}
        layout="vertical"
        initialValues={{
          enabled: true,
          node: 'self',
          exportStats: true,
          schema: 'SRT',
          schema_options: {
            'auto-reconnect': true,
            'keep-listening': false
          },
          ...initialValues
        }}
        onValuesChange={handleValuesChange}
      >
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
          <Row gutter={24}>
            <Col style={{ width: '100%', maxWidth: '1200px' }}>
              <Space direction="vertical" size="large" style={{ width: '100%' }}>
                {/* General Settings */}
                <Card title="General Options" size="small" loading={loading}>
                  <Form.Item
                    label="Name"
                    name="name"
                    required
                    tooltip="A unique name for this route"
                  >
                    <Input placeholder="Enter route name" />
                  </Form.Item>

                  <Form.Item
                    label="Enabled"
                    name="enabled"
                    valuePropName="checked"
                    extra="Auto start after server reboot"
                  >
                    <Switch />
                  </Form.Item>

                  <Form.Item
                    label="Export stats"
                    name="exportStats"
                    valuePropName="checked"
                    extra="Export stats to VictoriaMetrics/InfluxDB/Prometheus"
                  >
                    <Switch />
                  </Form.Item>

                  <Form.Item
                    label="Node"
                    name="node"
                    required
                    tooltip="Node where route will launch"
                  >
                    <Select
                      placeholder="Select a node"
                      options={availableNodes}
                      disabled={true}
                      style={{ width: '100%' }}
                    />
                  </Form.Item>
                </Card>

                <Card title="Source Options" size="small" loading={loading}>
                  <Form.Item
                    label="Schema"
                    name="schema"
                    required
                  >
                    <Radio.Group buttonStyle="solid">
                      <Radio.Button value="SRT">SRT</Radio.Button>
                      <Radio.Button value="UDP">UDP</Radio.Button>
                    </Radio.Group>
                  </Form.Item>

                  {/* SRT specific options */}
                  <Form.Item noStyle dependencies={['schema']}>
                    {({ getFieldValue }) =>
                      getFieldValue('schema') === 'SRT' && (
                        <>
                          <Form.Item
                            label="Mode"
                            name={['schema_options', 'mode']}
                            required
                            extra="The SRT connection mode. Caller: Actively initiates the connection to a Listener. Listener: Waits for an incoming connection from a Caller. Rendezvous: Both endpoints attempt to connect to each other simultaneously"
                          >
                            <Radio.Group buttonStyle="solid">
                              <Radio.Button value="caller">Caller</Radio.Button>
                              <Radio.Button value="listener">Listener</Radio.Button>
                              <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                            </Radio.Group>
                          </Form.Item>

                          <Form.Item
                            label="Local Address"
                            name={['schema_options', 'localaddress']}
                            extra="The address to bind when mode is listener or rendezvous. This property can be set by URI parameters."
                          >
                            <Input
                              placeholder="Enter address"
                              style={{ width: '100%' }}
                            />
                          </Form.Item>

                          <Form.Item
                            style={{ width: '150px' }}
                            size="5"
                            label="Local Port"
                            name={['schema_options', 'localport']}
                            required
                            tooltip="Port number (1-65535)"
                            rules={[
                              {
                                type: 'number',
                                min: 1,
                                max: 65535,
                                message: 'Port must be between 1 and 65535',
                              },
                            ]}
                          >
                            <InputNumber style={{ width: '100%' }} placeholder="Enter port number" />
                          </Form.Item>

                          <Form.Item
                            label="Latency"
                            name={['schema_options', 'latency']}
                            extra='The maximum accepted transmission latency.'
                          >
                            <InputNumber
                              style={{ width: '150px' }}
                              min={20}
                              max={8000}
                              placeholder="Default: 125ms"
                            />
                          </Form.Item>

                          <Form.Item
                            label="Auto Reconnect"
                            name={['schema_options', 'auto-reconnect']}
                            valuePropName="checked"
                            extra="When enabled, the connection will automatically try to reconnect if disconnected. This applies only in caller mode and will be ignored for authentication failures."
                          >
                            <Switch />
                          </Form.Item>

                          <Form.Item
                            label="Keep Listening"
                            name={['schema_options', 'keep-listening']}
                            valuePropName="checked"
                            extra="When enabled, the server will continue waiting for clients to reconnect after disconnection. When disabled, the stream will end immediately when a client disconnects. A 'connection-removed' message will be sent on disconnection."
                          >
                            <Switch />
                          </Form.Item>

                          <Form.Item
                            label="Authentication"
                            name={['schema_options', 'authentication']}
                            valuePropName="checked"
                            extra="Enable SRT authentication"
                          >
                            <Switch />
                          </Form.Item>

                          <Form.Item noStyle dependencies={[['schema_options', 'authentication']]}>
                            {({ getFieldValue }) =>
                              getFieldValue(['schema_options', 'authentication']) && (
                                <>
                                  <Form.Item
                                    label="Passphrase"
                                    name={['schema_options', 'passphrase']}
                                    required
                                    extra="Encryption passphrase for SRT authentication"
                                  >
                                    <Input.Password placeholder="Enter passphrase" />
                                  </Form.Item>

                                  <Form.Item
                                    label="Key Length"
                                    name={['schema_options', 'pbkeylen']}
                                    required
                                    extra="Encryption key length for SRT authentication"
                                  >
                                    <Select
                                      placeholder="Select key length"
                                      options={[
                                        { label: '0 (Default)', value: 0 },
                                        { label: '16', value: 16 },
                                        { label: '24', value: 24 },
                                        { label: '32', value: 32 },
                                      ]}
                                      style={{ width: '150px' }}
                                    />
                                  </Form.Item>
                                </>
                              )
                            }
                          </Form.Item>
                        </>
                      )
                    }
                  </Form.Item>

                  {/* UDP specific options */}
                  <Form.Item noStyle dependencies={['schema']}>
                    {({ getFieldValue }) =>
                      getFieldValue('schema') === 'UDP' && (
                        <>
                          <Form.Item
                            label="Address"
                            name={['schema_options', 'address']}
                            extra="Address to receive packets for. This is equivalent to the multicast-group property for now."
                          >
                            <Input
                              placeholder="Default: 0.0.0.0"
                              style={{ width: '100%' }}
                            />
                          </Form.Item>

                          <Form.Item
                            style={{ width: '150px' }}
                            size="5"
                            label="Port"
                            name={['schema_options', 'port']}
                            required
                            tooltip="Port number (1-65535)"
                            rules={[
                              {
                                type: 'number',
                                min: 1,
                                max: 65535,
                                message: 'Port must be between 1 and 65535',
                              },
                            ]}
                          >
                            <InputNumber style={{ width: '100%' }} placeholder="Enter port number" />
                          </Form.Item>
                          <Form.Item
                            style={{ width: '150px' }}
                            label="Buffer Size"
                            name={['schema_options', 'buffer-size']}
                            tooltip="UDP buffer size in bytes"
                          >
                            <InputNumber
                              style={{ width: '100%' }}
                              placeholder="Default: 0 bytes"
                            />
                          </Form.Item>

                          <Form.Item
                            style={{ width: '150px' }}
                            label="MTU"
                            name={['schema_options', 'mtu']}
                            tooltip="Maximum expected packet size. This directly defines the allocation size of the receive buffer pool."
                          >
                            <InputNumber
                              style={{ width: '100%' }}
                              placeholder="Default: 1492"
                            />
                          </Form.Item>
                        </>
                      )
                    }
                  </Form.Item>
                </Card>
              </Space>

              {id === 'new' && (
                <Card 
                  style={{ marginTop: '24px', backgroundColor: '#141414', border: '1px solid #303030' }}
                  size="small"
                >
                  <Space align="start">
                    <InfoCircleOutlined style={{ color: '#1890ff', fontSize: '16px', marginTop: '3px' }} />
                    <Typography.Text type="secondary">
                      Destination creation will be available after saving this source. Please save the source first to continue setting up your route.
                    </Typography.Text>
                  </Space>
                </Card>
              )}

              <Row justify="end" style={{ marginTop: '24px' }}>
                <Space>
                  <Button
                    icon={<CloseOutlined />}
                    onClick={handleCancel}
                  >
                    Cancel
                  </Button>
                  <Button
                    type="primary"
                    icon={<SaveOutlined />}
                    onClick={handleSave}
                  >
                    Save
                  </Button>
                </Space>
              </Row>
            </Col>
          </Row>
        </Space>
      </Form>
    </div>
  );
};

RouteSourceEdit.propTypes = {
  initialValues: PropTypes.object,
  onChange: PropTypes.func,
};

export default RouteSourceEdit; 