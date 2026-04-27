import { Form, Input, Radio, Card, Space, InputNumber, Switch, Select, Button, Row, Col, message, Typography, Modal, Descriptions } from 'antd';
import { InfoCircleOutlined, SaveOutlined, ArrowLeftOutlined, HomeOutlined, LoadingOutlined, ApiOutlined } from '@ant-design/icons';
import PropTypes from 'prop-types';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useState, useRef } from 'react';
import { interfacesApi, routesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

const normalizeSrtOptionsForForm = (route) => {
  if (!route || route.schema !== 'SRT') {
    return route;
  }

  const schemaOptions = route.schema_options || {};
  const mode = schemaOptions.mode;

  if (mode !== 'caller' && mode !== 'rendezvous') {
    return route;
  }

  const normalizedOptions = { ...schemaOptions };

  if (
    (normalizedOptions.address === undefined || normalizedOptions.address === null || normalizedOptions.address === '') &&
    typeof normalizedOptions.localaddress === 'string' &&
    normalizedOptions.localaddress !== ''
  ) {
    normalizedOptions.address = normalizedOptions.localaddress;
  }

  if (
    (normalizedOptions.port === undefined || normalizedOptions.port === null || normalizedOptions.port === '') &&
    normalizedOptions.localport !== undefined &&
    normalizedOptions.localport !== null &&
    normalizedOptions.localport !== ''
  ) {
    normalizedOptions.port = normalizedOptions.localport;
  }

  return {
    ...route,
    schema_options: normalizedOptions,
  };
};

const RouteSourceEdit = ({ initialValues, onChange }) => {
  const [form] = Form.useForm();
  const navigate = useNavigate();
  const { id } = useParams();
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const [loading, setLoading] = useState(id !== 'new');
  const [testingConnection, setTestingConnection] = useState(false);
  const [interfacesLoading, setInterfacesLoading] = useState(false);
  const [interfaceOptions, setInterfaceOptions] = useState([]);
  const dataFetchedRef = useRef(false);
  const [routeData, setRouteData] = useState(null);

  // Set breadcrumb items for the RouteSourceEdit page
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
          const normalizedRoute = normalizeSrtOptionsForForm(result.data);
          setRouteData(normalizedRoute);
          form.setFieldsValue(normalizedRoute);
          setLoading(false);
        })
        .catch(error => {
          messageApi.error(`Failed to fetch route data: ${error.message}`);
          console.error('Error:', error);
          setLoading(false);
        });
    }
  }, [id, form, messageApi]);

  useEffect(() => {
    let mounted = true;

    const loadInterfaces = async () => {
      setInterfacesLoading(true);

      try {
        const result = await interfacesApi.getAll();
        const rows = Array.isArray(result?.data) ? result.data : [];
        const enabledRows = rows.filter((item) => item?.enabled !== false);

        const options = enabledRows.map((item) => ({
          label: `${item.name || item.sys_name} (${item.sys_name} - ${item.ip || 'N/A'})`,
          value: item.sys_name,
          ip: item.ip,
        }));

        if (mounted) {
          setInterfaceOptions(options);
        }
      } catch (error) {
        if (mounted) {
          messageApi.error(`Failed to load interfaces: ${error.message}`);
        }
      } finally {
        if (mounted) {
          setInterfacesLoading(false);
        }
      }
    };

    loadInterfaces();

    return () => {
      mounted = false;
    };
  }, [messageApi]);

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

  const handleBack = () => {
    navigate(id === 'new' ? ROUTES.ROUTES : `/routes/${id}`);
  };

  const openProbeResultModal = (probeResult) => {
    const streams = probeResult?.streams || [];
    const format = probeResult?.format || {};
    const descriptionLabelStyle = { width: 180 };
    const descriptionContentStyle = { wordBreak: 'break-word' };

    modal.info({
      title: 'Connection Test Result',
      width: 900,
      content: (
        <Space direction="vertical" size="large" style={{ width: '100%', marginTop: 16 }}>
          <Descriptions
            bordered
            size="small"
            column={1}
            labelStyle={descriptionLabelStyle}
            contentStyle={descriptionContentStyle}
          >
            <Descriptions.Item label="Probe URI">
              <Typography.Text code>{probeResult?.probe_uri || 'N/A'}</Typography.Text>
            </Descriptions.Item>
            <Descriptions.Item label="Format">
              {format.format_name || 'Unknown'}
            </Descriptions.Item>
            <Descriptions.Item label="Bitrate">
              {format.bit_rate || 'Unknown'}
            </Descriptions.Item>
            <Descriptions.Item label="Duration">
              {format.duration || 'Unknown'}
            </Descriptions.Item>
          </Descriptions>

          <Typography.Title level={5} style={{ margin: 0 }}>
            Streams
          </Typography.Title>

          {streams.length > 0 ? (
            <Space direction="vertical" size="middle" style={{ width: '100%' }}>
              {streams.map((stream, index) => (
                <Descriptions
                  key={`${stream.index ?? index}-${stream.codec_type ?? 'stream'}`}
                  bordered
                  size="small"
                  column={1}
                  title={`Stream ${stream.index ?? index}`}
                  labelStyle={descriptionLabelStyle}
                  contentStyle={descriptionContentStyle}
                >
                  <Descriptions.Item label="Index">{stream.index ?? index}</Descriptions.Item>
                  <Descriptions.Item label="Type">{stream.codec_type || 'Unknown'}</Descriptions.Item>
                  <Descriptions.Item label="Codec">{stream.codec_name || 'Unknown'}</Descriptions.Item>
                  <Descriptions.Item label="Bitrate">{stream.bit_rate || 'Unknown'}</Descriptions.Item>
                  <Descriptions.Item label="Resolution">
                    {stream.width && stream.height ? `${stream.width}x${stream.height}` : 'N/A'}
                  </Descriptions.Item>
                  <Descriptions.Item label="Sample Rate">{stream.sample_rate || 'N/A'}</Descriptions.Item>
                  <Descriptions.Item label="Channels">{stream.channels || 'N/A'}</Descriptions.Item>
                </Descriptions>
              ))}
            </Space>
          ) : (
            <Typography.Text type="secondary">ffprobe did not return any streams.</Typography.Text>
          )}

          <Typography.Title level={5} style={{ margin: 0 }}>
            Raw Probe Data
          </Typography.Title>
          <pre
            style={{
              margin: 0,
              maxHeight: 320,
              overflow: 'auto',
              padding: 12,
              background: '#141414',
              border: '1px solid #303030',
              borderRadius: 8
            }}
          >
            {JSON.stringify(probeResult?.raw ?? probeResult, null, 2)}
          </pre>
        </Space>
      ),
      okText: 'Close'
    });
  };

  const handleTestConnection = () => {
    form.validateFields()
      .then(async (values) => {
        setTestingConnection(true);
        const loadingMessage = messageApi.loading('Testing source connection...', 0);

        try {
          const result = await routesApi.testSource(values);
          loadingMessage();
          messageApi.success('Connection test completed');
          openProbeResultModal(result.data);
        } catch (error) {
          loadingMessage();
          messageApi.error(`Failed to test source: ${error.message}`);
        } finally {
          setTestingConnection(false);
        }
      })
      .catch(() => {
        messageApi.error('Please check the form for errors');
      });
  };

  return (
    <div>
      {contextHolder}
      {modalContextHolder}

      {id === 'new' && (
        <Card 
          style={{ marginBottom: '24px', backgroundColor: '#141414', border: '1px solid #303030', maxWidth: '650px', width: '100%' }}
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
          <Space align="center" size="middle">
            <Button
              icon={<ArrowLeftOutlined />}
              onClick={handleBack}
            >
              Back
            </Button>
            <Title
              level={3}
              style={{
                margin: 0,
                fontSize: '1.75rem',
                fontWeight: 600
              }}
            >
              {id === 'new' ? 'Add Source' : 'Edit Source'}
            </Title>
          </Space>

          <Row gutter={24}>
            <Col style={{ width: '100%', maxWidth: '1200px' }}>
              <Space direction="vertical" size="large" style={{ width: '100%' }}>
                {/* General Settings */}
                <Card title="General Options" size="small" loading={loading} style={{ maxWidth: '650px', width: '100%' }}>
                  <Form.Item
                    label="Name"
                    name="name"
                    required
                    tooltip="A unique name for this route"
                    rules={[{ required: true, message: 'Please enter a route name' }]}
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
                    label="GST_DEBUG"
                    name="gstDebug"
                    tooltip="Set GStreamer debug level (e.g., GST_AUTOPLUG:6,GST_ELEMENT_*:4)"
                    extra="Configure GStreamer debug levels for detailed pipeline logging"
                    style={{ maxWidth: '450px' }}
                  >
                    <Input placeholder="Enter GStreamer debug configuration" />
                  </Form.Item>

                  <Form.Item
                    label="Node"
                    name="node"
                    required
                    tooltip="Node where route will launch"
                    rules={[{ required: true, message: 'Please select a node' }]}
                  >
                    <Select
                      placeholder="Select a node"
                      options={availableNodes}
                      disabled={true}
                      style={{ width: '100%' }}
                    />
                  </Form.Item>
                </Card>

                <Card title="Source Options" size="small" loading={loading} style={{ maxWidth: '650px', width: '100%' }}>
                  <Form.Item
                    label="Schema"
                    name="schema"
                    required
                    rules={[{ required: true, message: 'Please select a source schema' }]}
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
                            rules={[{ required: true, message: 'Please select an SRT mode' }]}
                          >
                            <Radio.Group buttonStyle="solid">
                              <Radio.Button value="caller">Caller</Radio.Button>
                              <Radio.Button value="listener">Listener</Radio.Button>
                              <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                            </Radio.Group>
                          </Form.Item>

                          <Form.Item
                            label="Interface"
                            name={['schema_options', 'interface_sys_name']}
                            extra="Select a local interface to bind SRT socket to."
                          >
                            <Select
                              allowClear
                              loading={interfacesLoading}
                              placeholder="Select interface"
                              options={interfaceOptions}
                              style={{ width: '100%' }}
                            />
                          </Form.Item>

                          <Form.Item noStyle dependencies={[['schema_options', 'mode']]}>
                            {({ getFieldValue }) => {
                              const mode = getFieldValue(['schema_options', 'mode']);
                              const isCaller = mode === 'caller';

                              return (
                                <Form.Item
                                  label={isCaller ? 'Remote Address' : 'Bind Address'}
                                  name={['schema_options', isCaller ? 'address' : 'localaddress']}
                                  extra={
                                    isCaller
                                      ? 'The remote host or IP address to connect to in caller mode.'
                                      : 'The local address to bind when mode is listener or rendezvous.'
                                  }
                                >
                                  <Input
                                    placeholder="Enter address"
                                    style={{ width: '100%' }}
                                  />
                                </Form.Item>
                              );
                            }}
                          </Form.Item>

                          <Form.Item noStyle dependencies={[['schema_options', 'mode']]}>
                            {({ getFieldValue }) => {
                              const mode = getFieldValue(['schema_options', 'mode']);
                              const isCaller = mode === 'caller';

                              return (
                                <Form.Item
                                  style={{ width: '150px' }}
                                  size="5"
                                  label={isCaller ? 'Remote Port' : 'Bind Port'}
                                  name={['schema_options', isCaller ? 'port' : 'localport']}
                                  required
                                  tooltip="Port number (1-65535)"
                                  rules={[
                                    {
                                      required: true,
                                      message: `Please enter a ${isCaller ? 'remote' : 'bind'} port`,
                                    },
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
                              );
                            }}
                          </Form.Item>

                          <Form.Item
                            label="Latency, ms"
                            name={['schema_options', 'latency']}
                            extra='The maximum accepted transmission latency.'
                          >
                            <InputNumber
                              style={{ width: '150px' }}
                              min={20}
                              max={8000}
                              placeholder="125"
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
                                    rules={[{ required: true, message: 'Please enter an SRT passphrase' }]}
                                  >
                                    <Input.Password placeholder="Enter passphrase" />
                                  </Form.Item>

                                  <Form.Item
                                    label="Key Length"
                                    name={['schema_options', 'pbkeylen']}
                                    required
                                    extra="Encryption key length for SRT authentication"
                                    rules={[{ required: true, message: 'Please select an SRT key length' }]}
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
                            label="Interface"
                            name={['schema_options', 'interface_sys_name']}
                            extra="Select a local interface for UDP bind/multicast settings."
                          >
                            <Select
                              allowClear
                              loading={interfacesLoading}
                              placeholder="Select interface"
                              options={interfaceOptions}
                              style={{ width: '100%' }}
                            />
                          </Form.Item>

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
                                required: true,
                                message: 'Please enter a UDP port',
                              },
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
                  style={{ marginTop: '24px', backgroundColor: '#141414', border: '1px solid #303030', maxWidth: '650px', width: '100%' }}
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
                    icon={<ArrowLeftOutlined />}
                    onClick={handleBack}
                  >
                    Back
                  </Button>
                  <Button
                    icon={<ApiOutlined />}
                    onClick={handleTestConnection}
                    loading={testingConnection}
                  >
                    Test Connection
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
