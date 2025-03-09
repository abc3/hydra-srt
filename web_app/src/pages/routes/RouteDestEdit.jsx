import {
    Form, Input, Radio,
    Card, Space,
    InputNumber,
    Switch, Select, Button,
    Row, Col, message, Typography
} from 'antd';
import { InfoCircleOutlined, SaveOutlined, CloseOutlined, HomeOutlined, LoadingOutlined } from '@ant-design/icons';
import PropTypes from 'prop-types';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useState, useRef } from 'react';
import { destinationsApi, routesApi } from '../../utils/api';
import React from 'react';

const { Title } = Typography;

const RouteDestEdit = ({ initialValues, onChange }) => {
    const [form] = Form.useForm();
    const navigate = useNavigate();
    const { routeId, destId } = useParams();
    const [messageApi, contextHolder] = message.useMessage();
    const [loading, setLoading] = useState(destId !== 'new');
    const dataFetchedRef = useRef(false);
    const [routeData, setRouteData] = useState(null);
    const [destData, setDestData] = useState(null);
    const [routeLoading, setRouteLoading] = useState(true);

    // Set breadcrumb items for the RouteDestEdit page
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
                    href: `/routes/${routeId}`,
                    title: routeLoading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
                },
                {
                    // Don't make the current page a link
                    title: destId === 'new' ? 'New Destination' : (loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (destData ? `Edit ${destData.name}` : 'Edit Destination')),
                }
            ]);
        }
    }, [routeId, destId, routeData, destData, loading, routeLoading]);

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

    // Fetch existing destination data when component mounts
    useEffect(() => {
        if (destId !== 'new' && !dataFetchedRef.current) {
            dataFetchedRef.current = true;

            destinationsApi.getById(routeId, destId)
                .then(result => {
                    setDestData(result.data);
                    form.setFieldsValue(result.data);
                    setLoading(false);
                })
                .catch(error => {
                    messageApi.error(`Failed to fetch destination data: ${error.message}`);
                    console.error('Error:', error);
                    setLoading(false);
                });
        }
    }, [routeId, destId, form, messageApi]);

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
                const loadingMessage = messageApi.loading('Saving destination...', 0);

                // Determine if we're creating or updating
                const savePromise = destId === 'new'
                    ? destinationsApi.create(routeId, values)
                    : destinationsApi.update(routeId, destId, values);

                savePromise
                    .then(data => {
                        loadingMessage();
                        messageApi.success('Destination saved successfully');
                        if (data) {
                            form.setFieldsValue(data.data);
                            // If this is a new destination, navigate to the route detail page
                            if (destId === 'new' && data.data.id) {
                                navigate(`/routes/${routeId}`);
                            }
                        }
                    })
                    .catch(error => {
                        loadingMessage();
                        messageApi.error(`Failed to save destination: ${error.message}`);
                        console.error('Error:', error);
                    });
            })
            .catch(info => {
                messageApi.error('Please check the form for errors');
                console.log('Validate Failed:', info);
            });
    };

    const handleCancel = () => {
        navigate(`/routes/${routeId}`);
    };

    return (
        <div>
            {contextHolder}
            {/* Page Title */}
            <Title 
                level={3} 
                style={{ 
                    margin: '0 0 24px 0', 
                    fontSize: '1.75rem', 
                    fontWeight: 600 
                }}
            >
                {destId === 'new' ? 'Add Destination' : 'Edit Destination'}
            </Title>

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
                    <Row gutter={24}>
                        <Col style={{ width: '100%', maxWidth: '1200px' }}>
                            <Space direction="vertical" size="large" style={{ width: '100%' }}>
                                {/* General Settings */}
                                <Card title="General Options" size="small" loading={loading}>
                                    <Form.Item
                                        label="Name"
                                        name="name"
                                        required
                                        extra="A unique name for this destination"
                                    >
                                        <Input placeholder="Enter destination name" />
                                    </Form.Item>
                                </Card>

                                {/* Destination Configuration */}
                                <Card title="Destination Options" size="small" loading={loading}>
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

                                    {/* SRT Specific Options */}
                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'SRT' && (
                                                <>
                                                    <Form.Item
                                                        label="Local Address"
                                                        name={['schema_options', 'localaddress']}
                                                        extra="Local address to bind."
                                                    >
                                                        <Input placeholder="Enter local address" />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Local Port"
                                                        name={['schema_options', 'localport']}
                                                        required
                                                        extra="Local port to bind."
                                                        rules={[
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
                                                    
                                                    <Form.Item
                                                        label="Mode"
                                                        name={['schema_options', 'mode']}
                                                        required
                                                        extra="Caller: Actively initiates the connection. Listener: Waits for incoming connections. Rendezvous: Both endpoints connect to each other simultaneously."
                                                    >
                                                        <Radio.Group buttonStyle="solid">
                                                            <Radio.Button value="caller">Caller</Radio.Button>
                                                            <Radio.Button value="listener">Listener</Radio.Button>
                                                            <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                                                        </Radio.Group>
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Latency"
                                                        name={['schema_options', 'latency']}
                                                        extra="The maximum accepted transmission latency in milliseconds"
                                                    >
                                                        <InputNumber
                                                            style={{ width: '150px' }}
                                                            min={20}
                                                            max={8000}
                                                            placeholder="Default: 125ms"
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
                                                        required
                                                        name={['schema_options', 'host']}
                                                        extra="The host/IP/Multicast group to send the packets to"
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

RouteDestEdit.propTypes = {
    initialValues: PropTypes.object,
    onChange: PropTypes.func,
};

export default RouteDestEdit; 