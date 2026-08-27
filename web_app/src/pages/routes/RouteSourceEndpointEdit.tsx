import {
    Form, Input, Radio,
    Card, Space,
    InputNumber,
    Switch, Select, Button,
    Row, Col, message, Typography
} from 'antd';
import { SaveOutlined, ArrowLeftOutlined, HomeOutlined, LoadingOutlined } from '@ant-design/icons';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useState, useRef } from 'react';
import { sourcesApi, interfacesApi, routesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';
import { applyBackendEndpointErrors, clearEndpointBindErrors } from './endpointFormErrors';
import { flattenEndpointPayload, normalizeEndpointForForm } from './endpointOptions';
import { buildInterfaceSelection } from './interfaceSelection';
import type { ApiDataResponse } from '../../types/api';
import type { EndpointFormValues, RouteSourceEndpointEditProps, RouteSummary } from '../../types/endpoints';
import type { AppError } from '../../types/errors';
import { getErrorMessage } from '../../types/errors';
import type { InterfaceOption, InterfaceRecord } from '../../types/interfaces';
import SrtAccessFields from './SrtAccessFields';
import ProtocolSchemaRadio from './ProtocolSchemaRadio';
import NdiInputFields from './NdiInputFields';
import MpegTsProgramField from './MpegTsProgramField';
import { useNdiCapabilities } from './useNdiCapabilities';

const { Title } = Typography;

const RouteSourceEndpointEdit = ({ initialValues, onChange }: RouteSourceEndpointEditProps) => {
    const [form] = Form.useForm();
    const navigate = useNavigate();
    const { routeId, sourceId } = useParams<{ routeId: string; sourceId: string }>();
    const [messageApi, contextHolder] = message.useMessage();
    const [loading, setLoading] = useState(sourceId !== 'new');
    const [interfacesLoading, setInterfacesLoading] = useState(false);
    const [interfaceOptions, setInterfaceOptions] = useState<InterfaceOption[]>([]);
    const [interfaceIpBySysName, setInterfaceIpBySysName] = useState<Record<string, string>>({});
    const [soleInterface, setSoleInterface] = useState<string | undefined>(undefined);
    const dataFetchedRef = useRef(false);
    const [routeData, setRouteData] = useState<RouteSummary | null>(null);
    const [sourceData, setSourceData] = useState<EndpointFormValues | null>(null);
    const [routeLoading, setRouteLoading] = useState(true);
    const { capabilities, loading: capabilitiesLoading } = useNdiCapabilities();
    const ndiFeatureEnabled = capabilities?.feature_enabled === true;

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
                .then((result: ApiDataResponse<RouteSummary>) => {
                    setRouteData(result.data ?? null);
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
        if (!routeId || !sourceId) {
            return;
        }

        if (sourceId !== 'new' && !dataFetchedRef.current) {
            dataFetchedRef.current = true;

            sourcesApi.get(routeId, sourceId)
                .then((result: ApiDataResponse<EndpointFormValues>) => {
                    const normalizedSource = normalizeEndpointForForm(result.data);
                    setSourceData((normalizedSource as EndpointFormValues) ?? null);
                    form.setFieldsValue((normalizedSource as EndpointFormValues) ?? {});
                    setLoading(false);
                })
                .catch(error => {
                    messageApi.error(`Failed to fetch source data: ${getErrorMessage(error, 'Unknown error')}`);
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
                const saved = Array.isArray((savedResult as ApiDataResponse<unknown[]>)?.data)
                    ? ((savedResult as ApiDataResponse<unknown[]>).data as InterfaceRecord[])
                    : [];
                const system = Array.isArray((systemResult as ApiDataResponse<unknown[]>)?.data)
                    ? ((systemResult as ApiDataResponse<unknown[]>).data as InterfaceRecord[])
                    : [];

                const selection = buildInterfaceSelection(saved, system);

                if (mounted) {
                    setInterfaceOptions(selection.options);
                    setInterfaceIpBySysName(selection.ipBySysName);
                    setSoleInterface(selection.soleInterface);
                }
            } catch (error) {
                if (mounted) {
                    messageApi.error(`Failed to load interfaces: ${getErrorMessage(error, 'Unknown error')}`);
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

    // With a single usable interface there is nothing to choose, so fill it in for a new
    // source. A saved source keeps whatever it stored, including a deliberate "Any interface".
    useEffect(() => {
        if (!soleInterface || sourceId !== 'new') {
            return;
        }

        if (form.getFieldValue('interface_sys_name')) {
            return;
        }

        // setFieldsValue (not setFieldValue) so fields that render off this value via
        // `dependencies` re-run — the bind address field is one of them.
        form.setFieldsValue({ interface_sys_name: soleInterface });
    }, [soleInterface, sourceId, form]);

    const handleValuesChange = (changedValues: Partial<EndpointFormValues>, allValues: EndpointFormValues) => {
        const changedKeys = Object.keys(changedValues || {});
        const bindRelevantKeys = ['interface_sys_name', 'address', 'localaddress', 'host', 'port', 'localport', 'multicast_iface', 'bind_address_option'];

        if (changedKeys.some((key) => bindRelevantKeys.includes(key))) {
            clearEndpointBindErrors(form);
        }

        if (onChange) {
            onChange(allValues);
        }
    };

    const handleSave = () => {
        if (!routeId || !sourceId) {
            messageApi.error('Route context is missing');
            return;
        }

        clearEndpointBindErrors(form);

        form.validateFields()
            .then((values: EndpointFormValues) => {
                const loadingMessage = messageApi.loading('Saving source...', 0);
                const payload = (flattenEndpointPayload(values) ?? values) as Record<string, unknown>;

                // Determine if we're creating or updating
                const savePromise: Promise<ApiDataResponse<EndpointFormValues>> = sourceId === 'new'
                    ? sourcesApi.create(routeId, payload) as Promise<ApiDataResponse<EndpointFormValues>>
                    : sourcesApi.update(routeId, sourceId, payload) as Promise<ApiDataResponse<EndpointFormValues>>;

                savePromise
                    .then((data) => {
                        loadingMessage();
                        messageApi.success('Source saved successfully');
                        if (data) {
                            form.setFieldsValue((normalizeEndpointForForm(data.data) as EndpointFormValues) ?? {});
                            // If this is a new source, navigate to the route detail page
                            if (sourceId === 'new' && data.data.id) {
                                navigate(`/routes/${routeId}`);
                            }
                        }
                    })
                    .catch(error => {
                        loadingMessage();
                        const backendErrors =
                            typeof error === 'object' && error !== null && 'errors' in error
                                ? (error as AppError).errors
                                : undefined;
                        if (applyBackendEndpointErrors(form, backendErrors)) {
                            messageApi.error('Please fix endpoint bind conflicts');
                            return;
                        }
                        messageApi.error(`Failed to save source: ${getErrorMessage(error, 'Unknown error')}`);
                        console.error('Error:', error);
                    });
            })
            .catch((info: unknown) => {
                messageApi.error('Please check the form for errors');
                console.log('Validate Failed:', info);
                const errorFields =
                    typeof info === 'object' &&
                    info !== null &&
                    'errorFields' in info &&
                    Array.isArray((info as { errorFields?: Array<{ name: unknown }> }).errorFields)
                        ? (info as { errorFields: Array<{ name: (string | number)[] }> }).errorFields
                        : [];
                if (errorFields[0]?.name) {
                    form.scrollToField(errorFields[0].name);
                }
            });
    };

    const handleBack = () => {
        if (!routeId) {
            navigate(ROUTES.ROUTES);
            return;
        }
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
                                        <ProtocolSchemaRadio direction="source" ndiFeatureEnabled={ndiFeatureEnabled} />
                                    </Form.Item>

                                    {/* SRT Specific Options */}
                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'SRT' && (
                                                <>
                                                    <Form.Item
                                                        label="Mode"
                                                        name="mode"
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
                                                        name="interface_sys_name"
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

                                                    <Form.Item noStyle dependencies={[['mode'], ['interface_sys_name']]}>
                                                        {({ getFieldValue: getNestedFieldValue }) => {
                                                            const mode = getNestedFieldValue(['mode']);
                                                            const isCaller = mode === 'caller';
                                                            const isRendezvous = mode === 'rendezvous';
                                                            const boundInterface = getNestedFieldValue(['interface_sys_name']);
                                                            const interfaceBindIp = boundInterface ? interfaceIpBySysName[boundInterface] : undefined;

                                                            return (
                                                                <>
                                                                    {(isCaller || isRendezvous) && (
                                                                        <Form.Item
                                                                            label="Remote Address"
                                                                            name="address"
                                                                            extra={isRendezvous ? 'Remote host/IP of the rendezvous peer.' : 'Remote host/IP for caller mode.'}
                                                                        >
                                                                            <Input placeholder="Enter remote address" />
                                                                        </Form.Item>
                                                                    )}

                                                                    {(isCaller || isRendezvous) && (
                                                                        <Form.Item
                                                                            label="Stream ID"
                                                                            name="streamid"
                                                                            preserve
                                                                            extra="Optional SRT Stream ID sent to the remote peer."
                                                                        >
                                                                            <Input placeholder="Enter Stream ID" />
                                                                        </Form.Item>
                                                                    )}

                                                                    {(!isCaller || isRendezvous) && (
                                                                        boundInterface ? (
                                                                            <Form.Item
                                                                                label="Bind Address"
                                                                                htmlFor="source_interface_bind_address"
                                                                                validateStatus={interfaceBindIp ? undefined : 'error'}
                                                                                extra={
                                                                                    interfaceBindIp
                                                                                        ? 'Taken from the selected interface.'
                                                                                        : `No address found on ${boundInterface}. This endpoint cannot bind until the interface has one.`
                                                                                }
                                                                            >
                                                                                <Input
                                                                                    id="source_interface_bind_address"
                                                                                    disabled
                                                                                    value={interfaceBindIp ?? ''}
                                                                                />
                                                                            </Form.Item>
                                                                        ) : (
                                                                            <Form.Item
                                                                                label="Bind Address"
                                                                                name="localaddress"
                                                                                extra={isRendezvous ? 'Local address to bind before connecting to the rendezvous peer.' : 'Local address to bind.'}
                                                                            >
                                                                                <Input placeholder="Enter bind address" />
                                                                            </Form.Item>
                                                                        )
                                                                    )}
                                                                </>
                                                            );
                                                        }}
                                                    </Form.Item>

                                                    <Form.Item noStyle dependencies={[['mode']]}>
                                                        {({ getFieldValue: getNestedFieldValue }) => {
                                                            const mode = getNestedFieldValue(['mode']);
                                                            const isCaller = mode === 'caller';
                                                            const isRendezvous = mode === 'rendezvous';

                                                            return (
                                                                <>
                                                                    {(isCaller || isRendezvous) && (
                                                                        <Form.Item
                                                                            label="Remote Port"
                                                                            name="port"
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
                                                                            name="localport"
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
                                                        name="latency"
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
                                                        name="authentication"
                                                        valuePropName="checked"
                                                        extra="Enable SRT authentication"
                                                    >
                                                        <Switch />
                                                    </Form.Item>

                                                    <Form.Item noStyle dependencies={['authentication']}>
                                                        {({ getFieldValue }) =>
                                                            getFieldValue('authentication') && (
                                                                <>
                                                                    <Form.Item
                                                                        label="Passphrase"
                                                                        name="passphrase"
                                                                        required
                                                                        extra="Encryption passphrase for SRT authentication"
                                                                        rules={[{ required: true, message: 'Please enter an SRT passphrase' }]}
                                                                    >
                                                                        <Input.Password placeholder="Enter passphrase" />
                                                                    </Form.Item>

                                                                    <Form.Item
                                                                        label="Key Length"
                                                                        name="pbkeylen"
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
                                                    <SrtAccessFields />
                                                    <MpegTsProgramField />
                                                </>
                                            )
                                        }
                                    </Form.Item>

                                    {/* RTMP specific options */}
                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'RTMP' && (
                                                <Form.Item
                                                    label="Path"
                                                    name="path"
                                                    required
                                                    extra="Publish to rtmp://YOUR_ADDR:1935/live/test"
                                                    rules={[{ required: true, message: 'Please enter an RTMP path' }]}
                                                >
                                                    <Input placeholder="/test/channel" />
                                                </Form.Item>
                                            )
                                        }
                                    </Form.Item>

                                    {/* UDP specific options */}
                                    <Form.Item noStyle dependencies={['schema', 'multicast']}>
                                        {({ getFieldValue }) =>
                                            (getFieldValue('schema') === 'UDP' || getFieldValue('schema') === 'RTP') && (
                                                (() => {
                                                    const isMulticast = getFieldValue('multicast') === true;

                                                    return (
                                                <>
                                                    <Form.Item
                                                        label="Interface"
                                                        name="interface_sys_name"
                                                        extra={isMulticast ? 'Required for joining the multicast group on the correct interface.' : 'Select a local interface for UDP/RTP bind settings.'}
                                                        rules={isMulticast ? [{ required: true, message: 'Please select a multicast interface' }] : []}
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
                                                        label="Multicast source"
                                                        name="multicast"
                                                        valuePropName="checked"
                                                        extra="Enable when this source receives packets from a UDP multicast group."
                                                    >
                                                        <Switch />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label={isMulticast ? 'Multicast Group' : 'Address'}
                                                        required
                                                        name="address"
                                                        extra={isMulticast ? 'The multicast group to join, for example 239.1.1.1.' : 'The local address to listen on.'}
                                                        rules={[{ required: true, message: isMulticast ? 'Please enter a multicast group' : 'Please enter a source address' }]}
                                                    >
                                                        <Input placeholder={isMulticast ? '239.1.1.1' : 'Enter address'} />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Port"
                                                        name="port"
                                                        required
                                                        extra="The local UDP port to listen on."
                                                        rules={[
                                                            {
                                                                required: true,
                                                                message: 'Please enter a source port',
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
                                                    <MpegTsProgramField />
                                                </>
                                                    );
                                                })()
                                            )
                                        }
                                    </Form.Item>

                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'NDI' && (
                                                <NdiInputFields
                                                    capabilities={capabilities}
                                                    capabilitiesLoading={capabilitiesLoading}
                                                    endpointId={sourceId !== 'new' ? sourceId : undefined}
                                                    savedSourceName={sourceData?.ndi_source_name}
                                                    savedObservedAddress={sourceData?.ndi_observed_address_snapshot}
                                                    savedObservedName={sourceData?.ndi_observed_name_snapshot}
                                                />
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

export default RouteSourceEndpointEdit; 
