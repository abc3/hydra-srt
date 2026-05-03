import {
    Form, Input, Radio,
    Card, Space,
    InputNumber,
    Switch, Select, Button,
    Row, Col, message, Typography
} from 'antd';
import { InfoCircleOutlined, SaveOutlined, ArrowLeftOutlined, HomeOutlined, LoadingOutlined } from '@ant-design/icons';
import PropTypes from 'prop-types';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useState, useRef } from 'react';
import { sourcesApi, interfacesApi, routesApi } from '../../utils/api';
import React from 'react';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

const normalizeSrtOptionsForForm = (source) => {
    if (!source || source.schema !== 'SRT') {
        return source;
    }

    const schemaOptions = source.schema_options || {};
    const mode = schemaOptions.mode;

    if (mode !== 'caller') {
        return source;
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
        ...source,
        schema_options: normalizedOptions,
    };
};

const RouteSourceEndpointEdit = ({ initialValues, onChange }) => {
    const [form] = Form.useForm();
    const navigate = useNavigate();
    const { routeId, sourceId } = useParams();
    const [messageApi, contextHolder] = message.useMessage();
    const [loading, setLoading] = useState(sourceId !== 'new');
    const [interfacesLoading, setInterfacesLoading] = useState(false);
    const [interfaceOptions, setInterfaceOptions] = useState([]);
    const dataFetchedRef = useRef(false);
    const [routeData, setRouteData] = useState(null);
    const [sourceData, setSourceData] = useState(null);
    const [routeLoading, setRouteLoading] = useState(true);

    // Set breadcrumb items for the RouteSourceEndpointEdit page
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
                    href: `/routes/${routeId}`,
                    title: routeLoading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
                },
                {
                    // Don't make the current page a link
                    title: sourceId === 'new' ? 'New Source' : (loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (sourceData ? `Edit ${sourceData.name}` : 'Edit Source')),
                }
            ]);
        }
    }, [routeId, sourceId, routeData, sourceData, loading, routeLoading]);

    // Fetch route data for breadcrumb
    useEffect(() => {
        if (routeId && routeId !== 'new') {
            setRouteLoading(true);
            routesApi.getById(routeId)
                .then(result => {
                    setRouteData(result.data);
                })
                .catch(error => {
                    console.error('Error fetching route data:', error);
                })
                .finally(() => {
                    setRouteLoading(false);
                });
        }
    }, [routeId]);

    // Fetch existing source data when component mounts
    useEffect(() => {
        if (sourceId !== 'new' && !dataFetchedRef.current) {
            dataFetchedRef.current = true;

            sourcesApi.get(routeId, sourceId)
                .then(result => {
                    const normalizedSource = normalizeSrtOptionsForForm(result.data);
                    setSourceData(normalizedSource);
                    form.setFieldsValue(normalizedSource);
                    setLoading(false);
                })
                .catch(error => {
                    messageApi.error(`Failed to fetch source data: ${error.message}`);
                    console.error('Error:', error);
                    setLoading(false);
                });
        }
    }, [routeId, sourceId, form, messageApi]);

    useEffect(() => {
        let mounted = true;

        const loadInterfaces = async () => {
            setInterfacesLoading(true);

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
                            name: aliasRecord?.name || '',
                            sys_name: item.sys_name,
                            ip: item.ip,
                            enabled: aliasRecord?.enabled ?? true,
                        };
                    }),
                    ...saved
                        .filter((item) => !system.some((systemItem) => systemItem.sys_name === item.sys_name))
                        .map((item) => ({
                            name: item.name,
                            sys_name: item.sys_name,
                            ip: item.ip,
                            enabled: item.enabled ?? true,
                        })),
                ];

                const enabledRows = mergedRows.filter((item) => item?.enabled !== false && item?.sys_name);

                const options = enabledRows.map((item) => ({
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
                const loadingMessage = messageApi.loading('Saving source...', 0);

                // Determine if we're creating or updating
                const savePromise = sourceId === 'new'
                    ? sourcesApi.create(routeId, values)
                    : sourcesApi.update(routeId, sourceId, values);

                savePromise
                    .then(data => {
                        loadingMessage();
                        messageApi.success('Source saved successfully');
                        if (data) {
                            form.setFieldsValue(data.data);
                            // If this is a new source, navigate to the route detail page
                            if (sourceId === 'new' && data.data.id) {
                                navigate(`/routes/${routeId}`);
                            }
                        }
                    })
                    .catch(error => {
                        loadingMessage();
                        messageApi.error(`Failed to save source: ${error.message}`);
                        console.error('Error:', error);
                    });
            })
            .catch(info => {
                messageApi.error('Please check the form for errors');
                console.log('Validate Failed:', info);
            });
    };

    const handleBack = () => {
        navigate(`/routes/${routeId}`);
    };

    return (
        <div>
            {contextHolder}
            <Form
                form={form}
                layout="vertical"
                initialValues={{
                    enabled: true,
                    node: 'self',
                    schema: 'SRT',
                    autoReconnect: true,
                    srtMode: 'caller',
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
                            {sourceId === 'new' ? 'Add Source' : 'Edit Source'}
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
                                        extra="A unique name for this source"
                                        rules={[{ required: true, message: 'Please enter a source name' }]}
                                    >
                                        <Input placeholder="Enter source name" />
                                    </Form.Item>

                                    <Form.Item
                                        label="Enabled"
                                        name="enabled"
                                        valuePropName="checked"
                                        extra="Disabled sources stay in the route config but are skipped when the route starts"
                                    >
                                        <Switch />
                                    </Form.Item>
                                </Card>

                                {/* Source Configuration */}
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

                                    {/* SRT Specific Options */}
                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'SRT' && (
                                                <>
                                                    <Form.Item
                                                        label="Mode"
                                                        name={['schema_options', 'mode']}
                                                        required
                                                        extra="Caller: Actively initiates the connection. Listener: Waits for incoming connections. Rendezvous: Both endpoints connect to each other simultaneously."
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
                                                        {({ getFieldValue: getNestedFieldValue }) => {
                                                            const mode = getNestedFieldValue(['schema_options', 'mode']);
                                                            const isCaller = mode === 'caller';
                                                            const isRendezvous = mode === 'rendezvous';

                                                            return (
                                                                <>
                                                                    {(isCaller || isRendezvous) && (
                                                                        <Form.Item
                                                                            label="Remote Address"
                                                                            name={['schema_options', 'address']}
                                                                            extra={isRendezvous ? 'Remote host/IP of the rendezvous peer.' : 'Remote host/IP for caller mode.'}
                                                                        >
                                                                            <Input placeholder="Enter remote address" />
                                                                        </Form.Item>
                                                                    )}

                                                                    {(!isCaller || isRendezvous) && (
                                                                        <Form.Item
                                                                            label="Bind Address"
                                                                            name={['schema_options', 'localaddress']}
                                                                            extra={isRendezvous ? 'Local address to bind before connecting to the rendezvous peer.' : 'Local address to bind.'}
                                                                        >
                                                                            <Input placeholder="Enter bind address" />
                                                                        </Form.Item>
                                                                    )}
                                                                </>
                                                            );
                                                        }}
                                                    </Form.Item>

                                                    <Form.Item noStyle dependencies={[['schema_options', 'mode']]}>
                                                        {({ getFieldValue: getNestedFieldValue }) => {
                                                            const mode = getNestedFieldValue(['schema_options', 'mode']);
                                                            const isCaller = mode === 'caller';
                                                            const isRendezvous = mode === 'rendezvous';

                                                            return (
                                                                <>
                                                                    {(isCaller || isRendezvous) && (
                                                                        <Form.Item
                                                                            label="Remote Port"
                                                                            name={['schema_options', 'port']}
                                                                            required
                                                                            extra="Remote port for caller/rendezvous mode."
                                                                            rules={[
                                                                                {
                                                                                    required: true,
                                                                                    message: 'Please enter a remote port',
                                                                                },
                                                                                {
                                                                                    type: 'number',
                                                                                    min: 1,
                                                                                    max: 65535,
                                                                                    message: 'Port must be between 1 and 65535',
                                                                                },
                                                                            ]}
                                                                        >
                                                                            <InputNumber
                                                                                style={{ width: '150px' }}
                                                                                placeholder="Enter remote port"
                                                                            />
                                                                        </Form.Item>
                                                                    )}

                                                                    {(!isCaller || isRendezvous) && (
                                                                        <Form.Item
                                                                            label="Bind Port"
                                                                            name={['schema_options', 'localport']}
                                                                            required
                                                                            extra="Local port to bind."
                                                                            rules={[
                                                                                {
                                                                                    required: true,
                                                                                    message: 'Please enter a bind port',
                                                                                },
                                                                                {
                                                                                    type: 'number',
                                                                                    min: 1,
                                                                                    max: 65535,
                                                                                    message: 'Port must be between 1 and 65535',
                                                                                },
                                                                            ]}
                                                                        >
                                                                            <InputNumber
                                                                                style={{ width: '150px' }}
                                                                                placeholder="Enter bind port"
                                                                            />
                                                                        </Form.Item>
                                                                    )}
                                                                </>
                                                            );
                                                        }}
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Latency, ms"
                                                        name={['schema_options', 'latency']}
                                                        extra="The maximum accepted transmission latency in milliseconds"
                                                    >
                                                        <InputNumber
                                                            style={{ width: '150px' }}
                                                            min={20}
                                                            max={8000}
                                                            placeholder="125"
                                                        />
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
                                                        required
                                                        name={['schema_options', 'host']}
                                                        extra="The host/IP/Multicast group to send the packets to"
                                                        rules={[{ required: true, message: 'Please enter a UDP source address' }]}
                                                    >
                                                        <Input placeholder="Enter address" />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Port"
                                                        name={['schema_options', 'port']}
                                                        required
                                                        extra="The port to send the packets to"
                                                        rules={[
                                                            {
                                                                required: true,
                                                                message: 'Please enter a UDP source port',
                                                            },
                                                            {
                                                                type: 'number',
                                                                min: 1,
                                                                max: 65535,
                                                                message: 'Port must be between 1 and 65535',
                                                            },
                                                        ]}
                                                    >
                                                        <InputNumber 
                                                            style={{ width: '150px' }} 
                                                            placeholder="Enter port number" 
                                                        />
                                                    </Form.Item>
                                                </>
                                            )
                                        }
                                    </Form.Item>
                                </Card>
                            </Space>

                            <Row justify="end" style={{ marginTop: '24px' }}>
                                <Space>
                                    <Button 
                                        icon={<ArrowLeftOutlined />} 
                                        onClick={handleBack}
                                    >
                                        Back
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

RouteSourceEndpointEdit.propTypes = {
    initialValues: PropTypes.object,
    onChange: PropTypes.func,
};

export default RouteSourceEndpointEdit; 
