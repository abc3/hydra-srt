import {
  Form,
  Input,
  Radio,
  Card,
  Space,
  InputNumber,
  Switch,
  Select,
  Button,
  Row,
  Col,
  message,
  Typography,
} from 'antd';
import {
  SaveOutlined,
  ArrowLeftOutlined,
  HomeOutlined,
  LoadingOutlined,
  ApiOutlined,
  PlusOutlined,
  DeleteOutlined,
} from '@ant-design/icons';
import PropTypes from 'prop-types';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useMemo, useRef, useState } from 'react';
import { interfacesApi, routesApi, sourcesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title, Text } = Typography;

const DEFAULT_SOURCE = {
  enabled: true,
  name: 'Primary',
  schema: 'SRT',
  schema_options: {
    mode: 'listener',
    'auto-reconnect': true,
    'keep-listening': false,
  },
};

const getInitialFormValues = (initialValues) => ({
  enabled: true,
  node: 'self',
  backup_config: {
    mode: 'passive',
    switch_after_ms: 3000,
    cooldown_ms: 10000,
    primary_stable_ms: 15000,
    probe_interval_ms: 5000,
  },
  sources: [DEFAULT_SOURCE],
  ...initialValues,
});

const RouteSourceEdit = ({ initialValues, onChange }) => {
  const [form] = Form.useForm();
  const navigate = useNavigate();
  const { id } = useParams();
  const [messageApi, contextHolder] = message.useMessage();
  const [loading, setLoading] = useState(id !== 'new');
  const [testingConnection, setTestingConnection] = useState(false);
  const [interfacesLoading, setInterfacesLoading] = useState(false);
  const [interfaceOptions, setInterfaceOptions] = useState([]);
  const [routeData, setRouteData] = useState(null);
  const dataFetchedRef = useRef(false);

  const isNew = id === 'new';

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        { href: ROUTES.ROUTES, title: <HomeOutlined /> },
        { href: ROUTES.ROUTES, title: 'Routes' },
        ...(id !== 'new'
          ? [
              {
                href: `/routes/${id}`,
                title: loading ? (
                  <>
                    <LoadingOutlined style={{ marginRight: 8 }} />Loading...
                  </>
                ) : routeData ? (
                  routeData.name
                ) : (
                  'Route Details'
                ),
              },
            ]
          : []),
        { title: id === 'new' ? 'New Route' : 'Edit Route' },
      ]);
    }
  }, [id, routeData, loading]);

  useEffect(() => {
    let mounted = true;

    const loadInterfaces = async () => {
      setInterfacesLoading(true);
      try {
        const result = await interfacesApi.getAll();
        const rows = Array.isArray(result?.data) ? result.data : [];
        const options = rows
          .filter((item) => item?.enabled !== false)
          .map((item) => ({
            label: `${item.name || item.sys_name} (${item.sys_name} - ${item.ip || 'N/A'})`,
            value: item.sys_name,
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

  useEffect(() => {
    if (isNew || dataFetchedRef.current) {
      return;
    }

    dataFetchedRef.current = true;

    routesApi
      .getById(id)
      .then((result) => {
        const route = result.data;
        const sources = Array.isArray(route?.sources) && route.sources.length > 0
          ? [...route.sources].sort((a, b) => (a.position || 0) - (b.position || 0))
          : [DEFAULT_SOURCE];

        const values = {
          ...route,
          sources,
          backup_config: {
            mode: 'passive',
            ...route.backup_config,
          },
        };

        setRouteData(route);
        form.setFieldsValue(values);
      })
      .catch((error) => {
        messageApi.error(`Failed to fetch route data: ${error.message}`);
      })
      .finally(() => setLoading(false));
  }, [id, isNew, form, messageApi]);

  const availableNodes = useMemo(() => [{ label: 'self', value: 'self' }], []);

  const handleValuesChange = (_changedValues, allValues) => {
    if (onChange) {
      onChange(allValues);
    }
  };

  const normalizeSourcePayload = (source, position) => ({
    enabled: source?.enabled !== false,
    name: source?.name,
    schema: source?.schema,
    schema_options: source?.schema_options || {},
    position,
  });

  const saveSources = async (routeId, sources, existingSources = []) => {
    const existingById = new Map(existingSources.filter((s) => s?.id).map((s) => [s.id, s]));
    const keptIds = [];

    for (let index = 0; index < sources.length; index += 1) {
      const source = sources[index];
      const payload = normalizeSourcePayload(source, index);

      if (source?.id && existingById.has(source.id)) {
        await sourcesApi.update(routeId, source.id, payload);
        keptIds.push(source.id);
      } else {
        const created = await sourcesApi.create(routeId, payload);
        if (created?.data?.id) {
          keptIds.push(created.data.id);
        }
      }
    }

    const deletedIds = existingSources
      .filter((source) => source?.id && !keptIds.includes(source.id))
      .map((source) => source.id);

    for (const sourceId of deletedIds) {
      await sourcesApi.delete(routeId, sourceId);
    }

    if (keptIds.length > 0) {
      await sourcesApi.reorder(routeId, keptIds);
    }

    return keptIds;
  };

  const handleSave = async () => {
    try {
      const values = await form.validateFields();
      const loadingMessage = messageApi.loading('Saving route...', 0);

      const routePayload = {
        name: values.name,
        enabled: values.enabled,
        node: values.node,
        gstDebug: values.gstDebug,
        backup_config: values.backup_config || {},
      };

      const sources = (values.sources || []).map((source, index) => normalizeSourcePayload(source, index));

      if (sources.length === 0) {
        loadingMessage();
        messageApi.error('At least one source is required');
        return;
      }

      let routeId = id;
      let existingSources = routeData?.sources || [];

      if (isNew) {
        const created = await routesApi.create(routePayload);
        routeId = created?.data?.id;
        if (!routeId) {
          throw new Error('Route id missing after create');
        }
      } else {
        await routesApi.update(routeId, routePayload);
      }

      const keptIds = await saveSources(routeId, values.sources || [], existingSources);

      if (!isNew && routeData?.active_source_id && !keptIds.includes(routeData.active_source_id) && keptIds[0]) {
        await routesApi.switchSource(routeId, keptIds[0]);
      }

      loadingMessage();
      messageApi.success('Route saved successfully');

      if (isNew) {
        navigate(`/routes/${routeId}`);
      } else {
        const refreshed = await routesApi.getById(routeId);
        setRouteData(refreshed.data);
        form.setFieldsValue({
          ...refreshed.data,
          sources: refreshed.data?.sources || values.sources,
        });
      }
    } catch (error) {
      if (error?.errorFields) {
        messageApi.error('Please check the form for errors');
        return;
      }

      messageApi.error(`Failed to save route: ${error.message}`);
    }
  };

  const handleTestConnection = async () => {
    try {
      const values = await form.validateFields();
      const firstSource = values?.sources?.[0];

      if (!firstSource) {
        messageApi.error('At least one source is required');
        return;
      }

      setTestingConnection(true);
      const loadingMessage = messageApi.loading('Testing source connection...', 0);

      const result = isNew
        ? await routesApi.testSource({
            schema: firstSource.schema,
            schema_options: firstSource.schema_options || {},
          })
        : firstSource.id
          ? await sourcesApi.test(id, firstSource.id)
          : await routesApi.testSource({
              schema: firstSource.schema,
              schema_options: firstSource.schema_options || {},
            });

      loadingMessage();
      messageApi.success(`Connection test completed (${(result?.data?.streams || []).length} streams)`);
    } catch (error) {
      if (!error?.errorFields) {
        messageApi.error(`Failed to test source: ${error.message}`);
      }
    } finally {
      setTestingConnection(false);
    }
  };

  const handleBack = () => navigate(isNew ? ROUTES.ROUTES : `/routes/${id}`);

  return (
    <div>
      {contextHolder}

      <Form
        form={form}
        layout="vertical"
        initialValues={getInitialFormValues(initialValues)}
        onValuesChange={handleValuesChange}
      >
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
          <Space align="center" size="middle">
            <Button icon={<ArrowLeftOutlined />} onClick={handleBack}>Back</Button>
            <Title level={3} style={{ margin: 0, fontSize: '1.75rem', fontWeight: 600 }}>
              {isNew ? 'Add Route' : 'Edit Route'}
            </Title>
          </Space>

          <Row gutter={24}>
            <Col style={{ width: '100%', maxWidth: '1200px' }}>
              <Space direction="vertical" size="large" style={{ width: '100%' }}>
                <Card title="General Options" size="small" loading={loading} style={{ maxWidth: '700px', width: '100%' }}>
                  <Form.Item label="Name" name="name" rules={[{ required: true, message: 'Please enter a route name' }]}>
                    <Input placeholder="Enter route name" />
                  </Form.Item>

                  <Form.Item label="Enabled" name="enabled" valuePropName="checked">
                    <Switch />
                  </Form.Item>

                  <Form.Item label="GST_DEBUG" name="gstDebug">
                    <Input placeholder="GST_AUTOPLUG:6,GST_ELEMENT_*:4" />
                  </Form.Item>

                  <Form.Item label="Node" name="node" rules={[{ required: true, message: 'Please select a node' }]}>
                    <Select options={availableNodes} disabled />
                  </Form.Item>
                </Card>

                <Card title="Backup Config" size="small" style={{ maxWidth: '700px', width: '100%' }}>
                  <Form.Item label="Mode" name={['backup_config', 'mode']}>
                    <Radio.Group buttonStyle="solid">
                      <Radio.Button value="active">Active</Radio.Button>
                      <Radio.Button value="passive">Passive</Radio.Button>
                      <Radio.Button value="disabled">Disabled</Radio.Button>
                    </Radio.Group>
                  </Form.Item>

                  <Row gutter={16}>
                    <Col><Form.Item label="Switch After (ms)" name={['backup_config', 'switch_after_ms']}><InputNumber min={0} /></Form.Item></Col>
                    <Col><Form.Item label="Cooldown (ms)" name={['backup_config', 'cooldown_ms']}><InputNumber min={0} /></Form.Item></Col>
                  </Row>

                  <Form.Item noStyle dependencies={[[ 'backup_config', 'mode' ]]}>
                    {({ getFieldValue }) => getFieldValue(['backup_config', 'mode']) === 'active' ? (
                      <Row gutter={16}>
                        <Col><Form.Item label="Primary Stable (ms)" name={['backup_config', 'primary_stable_ms']}><InputNumber min={0} /></Form.Item></Col>
                        <Col><Form.Item label="Probe Interval (ms)" name={['backup_config', 'probe_interval_ms']}><InputNumber min={0} /></Form.Item></Col>
                      </Row>
                    ) : null}
                  </Form.Item>
                </Card>

                <Form.List name="sources">
                  {(fields, { add, remove, move }) => (
                    <Space direction="vertical" size="middle" style={{ width: '100%', maxWidth: '700px' }}>
                      {fields.map((field, index) => (
                        <Card
                          key={field.key}
                          size="small"
                          title={index === 0 ? 'Primary Source' : `Backup Source #${index}`}
                          extra={(
                            <Space>
                              <Button size="small" onClick={() => index > 0 && move(index, index - 1)} disabled={index === 0}>Up</Button>
                              <Button size="small" onClick={() => index < fields.length - 1 && move(index, index + 1)} disabled={index === fields.length - 1}>Down</Button>
                              <Button size="small" danger icon={<DeleteOutlined />} onClick={() => remove(field.name)} disabled={fields.length === 1}>
                                Delete
                              </Button>
                            </Space>
                          )}
                        >
                          <Form.Item name={[field.name, 'id']} hidden><Input /></Form.Item>

                          <Form.Item label="Name" name={[field.name, 'name']} rules={[{ required: true, message: 'Please enter a source name' }]}>
                            <Input placeholder="Source name" />
                          </Form.Item>

                          <Form.Item label="Enabled" name={[field.name, 'enabled']} valuePropName="checked">
                            <Switch />
                          </Form.Item>

                          <Form.Item label="Schema" name={[field.name, 'schema']} rules={[{ required: true, message: 'Please select a source schema' }]}>
                            <Radio.Group buttonStyle="solid">
                              <Radio.Button value="SRT">SRT</Radio.Button>
                              <Radio.Button value="UDP">UDP</Radio.Button>
                            </Radio.Group>
                          </Form.Item>

                          <Form.Item noStyle dependencies={[[field.name, 'schema'], [field.name, 'schema_options', 'mode']]}>
                            {({ getFieldValue }) => {
                              const schema = getFieldValue(['sources', field.name, 'schema']);
                              const mode = getFieldValue(['sources', field.name, 'schema_options', 'mode']);

                              if (schema === 'SRT') {
                                const isCaller = mode === 'caller';
                                const isRendezvous = mode === 'rendezvous';

                                return (
                                  <>
                                    <Form.Item label="Mode" name={[field.name, 'schema_options', 'mode']} rules={[{ required: true, message: 'Please select an SRT mode' }]}>
                                      <Radio.Group buttonStyle="solid">
                                        <Radio.Button value="caller">Caller</Radio.Button>
                                        <Radio.Button value="listener">Listener</Radio.Button>
                                        <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                                      </Radio.Group>
                                    </Form.Item>

                                    <Form.Item label="Interface" name={[field.name, 'schema_options', 'interface_sys_name']}>
                                      <Select allowClear loading={interfacesLoading} options={interfaceOptions} placeholder="Select interface" />
                                    </Form.Item>

                                    {(isCaller || isRendezvous) && (
                                      <>
                                        <Form.Item label="Remote Address" name={[field.name, 'schema_options', 'address']}>
                                          <Input placeholder="Enter remote address" />
                                        </Form.Item>
                                        <Form.Item
                                          label="Remote Port"
                                          name={[field.name, 'schema_options', 'port']}
                                          rules={[
                                            { required: true, message: 'Please enter a remote port' },
                                            { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                          ]}
                                        >
                                          <InputNumber style={{ width: 180 }} />
                                        </Form.Item>
                                      </>
                                    )}

                                    {(!isCaller || isRendezvous) && (
                                      <>
                                        <Form.Item label="Bind Address" name={[field.name, 'schema_options', 'localaddress']}>
                                          <Input placeholder="Enter bind address" />
                                        </Form.Item>
                                        <Form.Item
                                          label="Bind Port"
                                          name={[field.name, 'schema_options', 'localport']}
                                          rules={[
                                            { required: true, message: 'Please enter a bind port' },
                                            { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                          ]}
                                        >
                                          <InputNumber style={{ width: 180 }} />
                                        </Form.Item>
                                      </>
                                    )}
                                  </>
                                );
                              }

                              if (schema === 'UDP') {
                                return (
                                  <>
                                    <Form.Item label="Interface" name={[field.name, 'schema_options', 'interface_sys_name']}>
                                      <Select allowClear loading={interfacesLoading} options={interfaceOptions} placeholder="Select interface" />
                                    </Form.Item>
                                    <Form.Item label="Address" name={[field.name, 'schema_options', 'address']}>
                                      <Input placeholder="0.0.0.0" />
                                    </Form.Item>
                                    <Form.Item
                                      label="Port"
                                      name={[field.name, 'schema_options', 'port']}
                                      rules={[
                                        { required: true, message: 'Please enter a UDP port' },
                                        { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                      ]}
                                    >
                                      <InputNumber style={{ width: 180 }} />
                                    </Form.Item>
                                  </>
                                );
                              }

                              return null;
                            }}
                          </Form.Item>
                        </Card>
                      ))}

                      <Button icon={<PlusOutlined />} onClick={() => add({ ...DEFAULT_SOURCE, name: `Backup ${fields.length}` })}>
                        Add Backup Source
                      </Button>
                    </Space>
                  )}
                </Form.List>

                {isNew && (
                  <Card style={{ maxWidth: '700px', width: '100%' }} size="small">
                    <Text type="secondary">Destination creation will be available after saving route and sources.</Text>
                  </Card>
                )}

                <Row justify="end" style={{ marginTop: 24 }}>
                  <Space>
                    <Button icon={<ArrowLeftOutlined />} onClick={handleBack}>Back</Button>
                    <Button icon={<ApiOutlined />} onClick={handleTestConnection} loading={testingConnection}>Test</Button>
                    <Button type="primary" icon={<SaveOutlined />} onClick={handleSave}>Save</Button>
                  </Space>
                </Row>
              </Space>
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

RouteSourceEdit.defaultProps = {
  initialValues: {},
  onChange: null,
};

export default RouteSourceEdit;
