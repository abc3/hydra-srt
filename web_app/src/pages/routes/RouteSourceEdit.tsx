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
  Drawer,
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
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useMemo, useRef, useState } from 'react';
import { destinationsApi, interfacesApi, routesApi, sourcesApi, tagsApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';
import type { ApiDataResponse } from '../../types/api';
import type { AppError } from '../../types/errors';
import { getErrorMessage } from '../../types/errors';
import type { InterfaceOption, InterfaceRecord } from '../../types/interfaces';
import {
  RouteEndpoint,
  RouteFormValues,
  RouteRecord,
  RouteSourceEditProps,
  SourceTestResult,
  TagOption,
} from '../../types/routes';
import { applyBackendEndpointErrors } from './endpointFormErrors';
import { flattenEndpointPayload, getEndpointOption, normalizeEndpointForForm } from './endpointOptions';
import type { EndpointRecord } from './endpointOptions';
import SrtAccessFields from './SrtAccessFields';

const { Title } = Typography;

type RouteEditFormValues = Omit<RouteFormValues, 'sources' | 'destinations'> & {
  sources?: EndpointRecord[];
  destinations?: EndpointRecord[];
};

const DEFAULT_SOURCE = {
  enabled: true,
  name: 'Primary',
  schema: 'SRT',
  mode: 'listener',
  auto_reconnect: true,
  keep_listening: false,
};

const DEFAULT_DESTINATION = {
  enabled: true,
  name: 'Destination 1',
  schema: 'UDP',
  mode: 'caller',
  auto_reconnect: true,
  host: '127.0.0.1',
};

const getInitialFormValues = (initialValues?: Partial<RouteEditFormValues>): RouteEditFormValues => ({
  enabled: true,
  node: 'self',
  backup_mode: 'passive',
  backup_switch_after_ms: 3000,
  backup_cooldown_ms: 10000,
  backup_primary_stable_ms: 15000,
  backup_probe_interval_ms: 5000,
  sources: [DEFAULT_SOURCE],
  destinations: [DEFAULT_DESTINATION],
  ...initialValues,
});

const normalizeRouteForForm = (route: RouteRecord | null | undefined): RouteEditFormValues | null | undefined => {
  if (!route) {
    return undefined;
  }

  return {
    ...route,
    sources: Array.isArray(route.sources)
      ? route.sources
        .map((source) => normalizeEndpointForForm(source as EndpointRecord))
        .filter((source): source is EndpointRecord => source != null)
      : [],
    destinations: Array.isArray(route.destinations)
      ? route.destinations
        .map((destination) => normalizeEndpointForForm(destination as EndpointRecord))
        .filter((destination): destination is EndpointRecord => destination != null)
      : [],
  };
};

const RouteSourceEdit = ({ initialValues = {}, onChange = null }: RouteSourceEditProps) => {
  const [form] = Form.useForm<RouteEditFormValues>();
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const [messageApi, contextHolder] = message.useMessage();
  const [loading, setLoading] = useState(id !== 'new');
  const [testingSourceIndex, setTestingSourceIndex] = useState<number | null>(null);
  const [interfacesLoading, setInterfacesLoading] = useState(false);
  const [interfaceOptions, setInterfaceOptions] = useState<InterfaceOption[]>([]);
  const [availableTags, setAvailableTags] = useState<TagOption[]>([]);
  const [routeData, setRouteData] = useState<RouteRecord | null>(null);
  const [testResultOpen, setTestResultOpen] = useState(false);
  const [testResultData, setTestResultData] = useState<SourceTestResult | null>(null);
  const dataFetchedRef = useRef(false);
  const previousSourceModesRef = useRef<(string | undefined)[]>([]);

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
        const [savedResult, systemResult] = await Promise.all([
          interfacesApi.getAll(),
          interfacesApi.getSystemInterfaces(),
        ]);
        const saved = (Array.isArray(savedResult?.data) ? savedResult.data : []) as InterfaceRecord[];
        const system = (Array.isArray(systemResult?.data) ? systemResult.data : []) as InterfaceRecord[];

        const savedBySysName = saved.reduce<Record<string, InterfaceRecord>>((acc, item) => {
          if (item?.sys_name) {
            acc[item.sys_name] = acc[item.sys_name] || item;
          }
          return acc;
        }, {});

        const mergedRows = [
          ...system.map((item: InterfaceRecord) => {
            const aliasRecord = savedBySysName[item.sys_name as string];
            return {
              name: aliasRecord?.name || '',
              sys_name: item.sys_name,
              ip: item.ip,
              enabled: aliasRecord?.enabled ?? true,
            };
          }),
          ...saved
            .filter((item: InterfaceRecord) => !system.some((systemItem) => systemItem.sys_name === item.sys_name))
            .map((item: InterfaceRecord) => ({
              name: item.name,
              sys_name: item.sys_name,
              ip: item.ip,
              enabled: item.enabled ?? true,
            })),
        ];

        const options = mergedRows
          .filter((item) => item?.enabled !== false && item?.sys_name)
          .map((item) => ({
            label: `${item.name || item.sys_name} (${item.sys_name} - ${item.ip || 'N/A'})`,
            value: item.sys_name as string,
          }))
          .filter((option): option is InterfaceOption => Boolean(option.value));

        if (mounted) {
          setInterfaceOptions(options);
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

  useEffect(() => {
    let mounted = true;

    tagsApi.getAll()
      .then((result) => {
        if (mounted) {
          const tags = Array.isArray(result?.data) ? result.data : [];
          setAvailableTags(tags.map((tag: string) => ({ label: tag, value: tag })));
        }
      })
      .catch((error) => {
        console.error('Failed to load tag suggestions', error);
      });

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
      .getById(id as string)
      .then((result) => {
        const rawRoute = (result as ApiDataResponse<RouteRecord>).data;
        const route = normalizeRouteForForm(rawRoute);
        const sources = Array.isArray(route?.sources) && route.sources.length > 0
          ? [...route.sources].sort(
            (a, b) => Number(getEndpointOption<number>(a, 'position') ?? 0) - Number(getEndpointOption<number>(b, 'position') ?? 0),
          )
          : [DEFAULT_SOURCE];

        const values: RouteEditFormValues = {
          ...route,
          node: route?.node || 'self',
          sources,
          destinations: Array.isArray(route?.destinations) && route.destinations.length > 0
            ? route.destinations
            : [DEFAULT_DESTINATION],
          backup_mode: route?.backup_mode || 'passive',
          backup_switch_after_ms: route?.backup_switch_after_ms ?? 3000,
          backup_cooldown_ms: route?.backup_cooldown_ms ?? 10000,
          backup_primary_stable_ms: route?.backup_primary_stable_ms ?? 15000,
          backup_probe_interval_ms: route?.backup_probe_interval_ms ?? 5000,
        };

        setRouteData(rawRoute);
        form.setFieldsValue(values as Parameters<typeof form.setFieldsValue>[0]);
      })
      .catch((error) => {
        messageApi.error(`Failed to fetch route data: ${getErrorMessage(error, 'Unknown error')}`);
      })
      .finally(() => setLoading(false));
  }, [id, isNew, form, messageApi]);

  const availableNodes = useMemo(() => [{ label: 'self', value: 'self' }], []);

  const handleValuesChange = (_changedValues: Partial<RouteEditFormValues>, allValues: RouteEditFormValues) => {
    const sources = Array.isArray(allValues?.sources) ? allValues.sources : [];
    const previousModes = previousSourceModesRef.current;
    const patchedSources: EndpointRecord[] = [...sources as EndpointRecord[]];
    let hasModeSyncChanges = false;

    const isEmpty = (value: unknown) => value === undefined || value === null || value === '';

    for (let index = 0; index < sources.length; index += 1) {
      const source = (sources[index] || {}) as EndpointRecord;
      const currentMode = source?.mode;
      const previousMode = previousModes[index];

      if (!currentMode || currentMode === previousMode) {
        continue;
      }

      const nextSource = { ...source };

      // Keep values when switching between caller/listener style fields.
      if ((currentMode === 'caller' || currentMode === 'rendezvous') && isEmpty(nextSource.address) && !isEmpty(nextSource.localaddress)) {
        nextSource.address = nextSource.localaddress;
        hasModeSyncChanges = true;
      }

      if ((currentMode === 'caller' || currentMode === 'rendezvous') && isEmpty(nextSource.port) && !isEmpty(nextSource.localport)) {
        nextSource.port = nextSource.localport as EndpointRecord['port'];
        hasModeSyncChanges = true;
      }

      if ((currentMode === 'listener' || currentMode === 'rendezvous') && isEmpty(nextSource.localaddress) && !isEmpty(nextSource.address)) {
        nextSource.localaddress = nextSource.address;
        hasModeSyncChanges = true;
      }

      if ((currentMode === 'listener' || currentMode === 'rendezvous') && isEmpty(nextSource.localport) && !isEmpty(nextSource.port)) {
        nextSource.localport = nextSource.port;
        hasModeSyncChanges = true;
      }

      patchedSources[index] = nextSource;
    }

    const nextSources = hasModeSyncChanges ? patchedSources : sources;
    if (hasModeSyncChanges) {
      form.setFieldsValue({ sources: nextSources } as Parameters<typeof form.setFieldsValue>[0]);
    }

    previousSourceModesRef.current = nextSources.map((source) => source?.mode);

    if (onChange) {
      onChange({ ...allValues, sources: nextSources } as RouteFormValues);
    }
  };

  const normalizeSourcePayload = (source: EndpointRecord, position: number) => ({
    ...flattenEndpointPayload(source),
    enabled: source?.enabled !== false,
    name: source?.name,
    schema: source?.schema,
    position,
  });

  const normalizeDestinationPayload = (destination: EndpointRecord) => ({
    ...flattenEndpointPayload(destination),
    enabled: destination?.enabled !== false,
    name: destination?.name,
    schema: destination?.schema,
  });

  const saveSources = async (routeId: string, sources: EndpointRecord[], existingSources: RouteEndpoint[] = []) => {
    const existingById = new Map(
      existingSources.filter((s) => s?.id).map((s) => [String(s.id), s]),
    );
    const keptIds: string[] = [];

    for (let index = 0; index < sources.length; index += 1) {
      const source = sources[index];
      const payload = normalizeSourcePayload(source, index);

      try {
        const sourceId = source?.id ? String(source.id) : undefined;
        if (sourceId && existingById.has(sourceId)) {
          await sourcesApi.update(routeId, sourceId, payload);
          keptIds.push(sourceId);
        } else {
          const created = (await sourcesApi.create(routeId, payload)) as ApiDataResponse<{ id: string }>;
          if (created.data?.id) {
            keptIds.push(created.data.id);
          }
        }
      } catch (error) {
        const appError = error as AppError & { userFacingMessage?: string };
        if (applyBackendEndpointErrors(form, appError.errors, ['sources', index])) {
          appError.userFacingMessage = 'Please fix source bind conflicts';
          throw appError;
        }
        throw error;
      }
    }

    const deletedIds = existingSources
      .filter((source) => source?.id && !keptIds.includes(String(source.id)))
      .map((source) => String(source.id));

    for (const sourceId of deletedIds) {
      await sourcesApi.delete(routeId, sourceId);
    }

    if (keptIds.length > 0) {
      await sourcesApi.reorder(routeId, keptIds);
    }

    return keptIds;
  };

  const createDestinations = async (routeId: string, destinations: EndpointRecord[]) => {
    for (let index = 0; index < destinations.length; index += 1) {
      const destination = destinations[index];
      const payload = normalizeDestinationPayload(destination);
      try {
        await destinationsApi.create(routeId, payload);
      } catch (error) {
        const appError = error as AppError & { userFacingMessage?: string };
        if (applyBackendEndpointErrors(form, appError.errors, ['destinations', index])) {
          appError.userFacingMessage = 'Please fix destination bind conflicts';
          throw appError;
        }
        throw error;
      }
    }
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
        backup_mode: values.backup_mode,
        backup_switch_after_ms: values.backup_switch_after_ms,
        backup_cooldown_ms: values.backup_cooldown_ms,
        backup_primary_stable_ms: values.backup_primary_stable_ms,
        backup_probe_interval_ms: values.backup_probe_interval_ms,
        tags: Array.isArray(values.tags) ? values.tags : [],
      };

      const destinations = values.destinations || [];
      const sources = values.sources || [];

      let routeId = id;

      if (isNew) {
        if (sources.length === 0) {
          loadingMessage();
          messageApi.error('At least one source is required');
          return;
        }

        if (destinations.length === 0) {
          loadingMessage();
          messageApi.error('At least one destination is required');
          return;
        }

        const created = (await routesApi.create(routePayload)) as ApiDataResponse<{ id: string }>;
        routeId = created.data?.id;
        if (!routeId) {
          throw new Error('Route id missing after create');
        }

        const keptIds = await saveSources(routeId, sources, []);
        await createDestinations(routeId, destinations);

        if (routeData?.active_source_id && !keptIds.includes(routeData.active_source_id) && keptIds[0]) {
          await routesApi.switchSource(routeId, keptIds[0]);
        }
      } else {
        await routesApi.update(routeId as string, routePayload);
      }

      loadingMessage();
      messageApi.success('Route saved successfully');

      if (isNew) {
        navigate(`/routes/${routeId}`);
      } else {
        const refreshedRaw = (await routesApi.getById(routeId as string) as ApiDataResponse<RouteRecord>).data;
        const refreshed = normalizeRouteForForm(refreshedRaw);
        setRouteData(refreshedRaw);
        form.setFieldsValue({
          ...refreshed,
          sources: refreshed?.sources || values.sources,
          destinations: refreshed?.destinations || routeData?.destinations,
        } as Parameters<typeof form.setFieldsValue>[0]);
      }
    } catch (error) {
      const saveError = error as AppError & {
        errorFields?: { errors?: string[] }[];
        userFacingMessage?: string;
      };

      if (saveError.errorFields) {
        const firstError = saveError.errorFields.find((field) => Array.isArray(field?.errors) && field.errors.length > 0);
        const firstErrorMessage = firstError?.errors?.[0] || 'Please check the form for errors';
        messageApi.error(`Validation error: ${firstErrorMessage}`);
        return;
      }

      if (saveError.userFacingMessage) {
        messageApi.error(saveError.userFacingMessage);
        return;
      }

      messageApi.error(`Failed to save route: ${getErrorMessage(error, 'Unknown error')}`);
    }
  };

  const handleTestConnection = async (sourceIndex = 0) => {
    if (testingSourceIndex !== null) {
      return;
    }

    try {
      const source = form.getFieldValue(['sources', sourceIndex]);

      if (!source) {
        messageApi.error('At least one source is required');
        return;
      }

      const schema = source?.schema;
      const mode = getEndpointOption(source, 'mode');
      const authEnabled = !!getEndpointOption(source, 'authentication');
      const needsRemote = mode === 'caller' || mode === 'rendezvous';
      const needsBind = mode === 'listener' || mode === 'rendezvous';
      const pathsToValidate = [
        ['sources', sourceIndex, 'schema'],
      ];

      if (schema === 'SRT') {
        pathsToValidate.push(['sources', sourceIndex, 'mode']);
        if (needsRemote) {
          pathsToValidate.push(['sources', sourceIndex, 'address']);
          pathsToValidate.push(['sources', sourceIndex, 'port']);
        }
        if (needsBind) {
          pathsToValidate.push(['sources', sourceIndex, 'localaddress']);
          pathsToValidate.push(['sources', sourceIndex, 'localport']);
        }
        if (authEnabled) {
          pathsToValidate.push(['sources', sourceIndex, 'passphrase']);
          pathsToValidate.push(['sources', sourceIndex, 'pbkeylen']);
        }
      }

      if (schema === 'UDP' || schema === 'RTP') {
        pathsToValidate.push(['sources', sourceIndex, 'port']);
        if (getEndpointOption(source, 'multicast')) {
          pathsToValidate.push(['sources', sourceIndex, 'address']);
          pathsToValidate.push(['sources', sourceIndex, 'interface_sys_name']);
        }
      }

      if (schema === 'RTMP') {
        pathsToValidate.push(['sources', sourceIndex, 'path']);
      }

      await form.validateFields(pathsToValidate);

      setTestingSourceIndex(sourceIndex);
      const loadingMessage = messageApi.loading('Testing source connection...', 0);

      const result = isNew
        ? await routesApi.testSource({
            schema: source.schema,
            ...flattenEndpointPayload(source),
          })
        : source.id
          ? await sourcesApi.test(id as string, String(source.id))
          : await routesApi.testSource({
              schema: source.schema,
              ...flattenEndpointPayload(source),
            });

      loadingMessage();
      setTestResultData(result?.data || result || null);
      setTestResultOpen(true);
      messageApi.success(`Connection test completed (${(result?.data?.streams || []).length} streams)`);
    } catch (error) {
      const testError = error as { errorFields?: unknown };
      if (!testError.errorFields) {
        messageApi.error(`Failed to test source: ${getErrorMessage(error, 'Unknown error')}`);
      }
    } finally {
      setTestingSourceIndex(null);
    }
  };

  const handleBack = () => navigate(isNew ? ROUTES.ROUTES : `/routes/${id}`);

  return (
    <div>
      {contextHolder}
      <Drawer
        title="Source Test Result"
        placement="right"
        width={560}
        open={testResultOpen}
        onClose={() => setTestResultOpen(false)}
      >
        <pre style={{ margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
          {JSON.stringify(testResultData, null, 2)}
        </pre>
      </Drawer>

      <Form
        form={form}
        layout="vertical"
        preserve
        scrollToFirstError={{ behavior: 'smooth', block: 'center' }}
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

                  <Form.Item label="Tags" name="tags">
                    <Select
                      mode="tags"
                      placeholder="Select or create tags"
                      tokenSeparators={[',', ' ']}
                      options={availableTags}
                      style={{ width: '100%' }}
                    />
                  </Form.Item>
                </Card>

                <Card title="Source failover backup" size="small" style={{ maxWidth: '700px', width: '100%' }}>
                  <Form.Item
                    label="Mode"
                    name="backup_mode"
                    extra="Active: auto-failover + auto-return to primary when stable. Passive: failover only, no auto-return. Disabled: no automatic failover."
                  >
                    <Radio.Group buttonStyle="solid">
                      <Radio.Button value="active">Active</Radio.Button>
                      <Radio.Button value="passive">Passive</Radio.Button>
                      <Radio.Button value="disabled">Disabled</Radio.Button>
                    </Radio.Group>
                  </Form.Item>

                  <Row gutter={16}>
                    <Col>
                      <Form.Item
                        label="Switch After (ms)"
                        name="backup_switch_after_ms"
                        extra="Debounce window before automatic switch on reconnecting/zero-bitrate conditions."
                      >
                        <InputNumber min={0} />
                      </Form.Item>
                    </Col>
                    <Col>
                      <Form.Item
                        label="Cooldown (ms)"
                        name="backup_cooldown_ms"
                        extra="Minimum time between automatic switches to prevent flapping."
                      >
                        <InputNumber min={0} />
                      </Form.Item>
                    </Col>
                  </Row>

                  <Form.Item noStyle dependencies={['backup_mode']}>
                    {({ getFieldValue }) => getFieldValue('backup_mode') === 'active' ? (
                      <Row gutter={16}>
                        <Col>
                          <Form.Item
                            label="Primary Stable (ms)"
                            name="backup_primary_stable_ms"
                            extra="How long primary must stay healthy before automatic return from backup."
                          >
                            <InputNumber min={0} />
                          </Form.Item>
                        </Col>
                        <Col>
                          <Form.Item
                            label="Probe Interval (ms)"
                            name="backup_probe_interval_ms"
                            extra="How often primary source health is checked while running on backup."
                          >
                            <InputNumber min={0} />
                          </Form.Item>
                        </Col>
                      </Row>
                    ) : null}
                  </Form.Item>
                </Card>

                {
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
                              <Button
                                size="small"
                                icon={<ApiOutlined />}
                                onClick={() => handleTestConnection(index)}
                                loading={testingSourceIndex === index}
                              >
                                Test connection
                              </Button>
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
                              <Radio.Button value="RTP">RTP</Radio.Button>
                              <Radio.Button value="RTMP">RTMP</Radio.Button>
                            </Radio.Group>
                          </Form.Item>

                          <Form.Item noStyle dependencies={[['sources', field.name, 'schema'], ['sources', field.name, 'mode'], ['sources', field.name, 'multicast']]}>
                            {({ getFieldValue }) => {
                              const schema = getFieldValue(['sources', field.name, 'schema']);
                              const mode = getFieldValue(['sources', field.name, 'mode']);
                              const isMulticast = getFieldValue(['sources', field.name, 'multicast']) === true;

                              if (schema === 'SRT') {
                                const isCaller = mode === 'caller';
                                const isRendezvous = mode === 'rendezvous';
                                const showRemote = isCaller || isRendezvous;
                                const showBind = !isCaller || isRendezvous;

                                return (
                                  <>
                                    <Form.Item label="Mode" name={[field.name, 'mode']} rules={[{ required: true, message: 'Please select an SRT mode' }]}>
                                      <Radio.Group buttonStyle="solid">
                                        <Radio.Button value="caller">Caller</Radio.Button>
                                        <Radio.Button value="listener">Listener</Radio.Button>
                                        <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                                      </Radio.Group>
                                    </Form.Item>

                                    <Form.Item label="Interface" name={[field.name, 'interface_sys_name']}>
                                      <Select allowClear loading={interfacesLoading} options={interfaceOptions} placeholder="Select interface" />
                                    </Form.Item>

                                    <Form.Item
                                      key={`source-${field.key}-remote-address`}
                                      label="Remote Address"
                                      name={[field.name, 'address']}
                                      hidden={!showRemote}
                                      preserve
                                      rules={showRemote ? [{ required: true, message: 'Please enter a remote address' }] : []}
                                    >
                                      <Input placeholder="Enter remote address" />
                                    </Form.Item>
                                    <Form.Item
                                      key={`source-${field.key}-remote-port`}
                                      label="Remote Port"
                                      name={[field.name, 'port']}
                                      hidden={!showRemote}
                                      preserve
                                      rules={showRemote
                                        ? [
                                            { required: true, message: 'Please enter a remote port' },
                                            { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                          ]
                                        : []}
                                    >
                                      <InputNumber style={{ width: 180 }} />
                                    </Form.Item>

                                    <Form.Item
                                      key={`source-${field.key}-bind-address`}
                                      label="Bind Address"
                                      name={[field.name, 'localaddress']}
                                      hidden={!showBind}
                                      preserve
                                      rules={showBind ? [{ required: true, message: 'Please enter a bind address' }] : []}
                                    >
                                      <Input placeholder="Enter bind address" />
                                    </Form.Item>
                                    <Form.Item
                                      key={`source-${field.key}-bind-port`}
                                      label="Bind Port"
                                      name={[field.name, 'localport']}
                                      hidden={!showBind}
                                      preserve
                                      rules={showBind
                                        ? [
                                            { required: true, message: 'Please enter a bind port' },
                                            { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                          ]
                                        : []}
                                    >
                                      <InputNumber style={{ width: 180 }} />
                                    </Form.Item>

                                    <Form.Item
                                      label="Authentication"
                                      name={[field.name, 'authentication']}
                                      valuePropName="checked"
                                      extra="Enable SRT authentication"
                                    >
                                      <Switch />
                                    </Form.Item>

                                    <Form.Item noStyle dependencies={[['sources', field.name, 'authentication']]}>
                                      {({ getFieldValue: getNestedFieldValue }) =>
                                        getNestedFieldValue(['sources', field.name, 'authentication']) && (
                                          <>
                                            <Form.Item
                                              label="Passphrase"
                                              name={[field.name, 'passphrase']}
                                              rules={[{ required: true, message: 'Please enter an SRT passphrase' }]}
                                              extra="Encryption passphrase for SRT authentication"
                                            >
                                              <Input.Password placeholder="Enter passphrase" />
                                            </Form.Item>

                                            <Form.Item
                                              label="Key Length"
                                              name={[field.name, 'pbkeylen']}
                                              rules={[{ required: true, message: 'Please select an SRT key length' }]}
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
                                                style={{ width: 180 }}
                                              />
                                            </Form.Item>
                                          </>
                                        )
                                      }
                                    </Form.Item>

                                    <SrtAccessFields sourceName={field.name} />
                                  </>
                                );
                              }

                              if (schema === 'UDP' || schema === 'RTP') {
                                return (
                                  <>
                                    <Form.Item
                                      label="Interface"
                                      name={[field.name, 'interface_sys_name']}
                                      extra={isMulticast ? 'Required for joining the multicast group on the correct interface.' : 'Optional local interface for UDP/RTP bind settings.'}
                                      rules={isMulticast ? [{ required: true, message: 'Please select a multicast interface' }] : []}
                                    >
                                      <Select allowClear loading={interfacesLoading} options={interfaceOptions} placeholder="Select interface" />
                                    </Form.Item>
                                    <Form.Item
                                      label="Multicast source"
                                      name={[field.name, 'multicast']}
                                      valuePropName="checked"
                                      extra="Enable when this source receives packets from a UDP multicast group."
                                    >
                                      <Switch />
                                    </Form.Item>
                                    <Form.Item
                                      label={isMulticast ? 'Multicast Group' : 'Address'}
                                      name={[field.name, 'address']}
                                      rules={isMulticast ? [{ required: true, message: 'Please enter a multicast group' }] : []}
                                      extra={isMulticast ? 'The multicast group to join, for example 239.1.1.1.' : 'Local address to listen on. Leave empty to listen on all interfaces.'}
                                    >
                                      <Input placeholder={isMulticast ? '239.1.1.1' : '0.0.0.0'} />
                                    </Form.Item>
                                    <Form.Item
                                      label="Port"
                                      name={[field.name, 'port']}
                                      rules={[
                                        { required: true, message: 'Please enter a source port' },
                                        { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                      ]}
                                    >
                                      <InputNumber style={{ width: 180 }} />
                                    </Form.Item>
                                  </>
                                );
                              }

                              if (schema === 'RTMP') {
                                return (
                                  <Form.Item
                                    label="Path"
                                    name={[field.name, 'path']}
                                    rules={[{ required: true, message: 'Please enter an RTMP path' }]}
                                    extra="Publish to rtmp://YOUR_ADDR:1935/live/test"
                                  >
                                    <Input placeholder="/test/channel" />
                                  </Form.Item>
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
                }

                {
                  <Form.List name="destinations">
                    {(fields, { add, remove }) => (
                      <Space direction="vertical" size="middle" style={{ width: '100%', maxWidth: '700px' }}>
                        {fields.map((field, index) => (
                          <Card
                            key={field.key}
                            size="small"
                            title={`Destination #${index + 1}`}
                            extra={(
                              <Button
                                size="small"
                                danger
                                icon={<DeleteOutlined />}
                                onClick={() => remove(field.name)}
                                disabled={fields.length === 1}
                              >
                                Delete
                              </Button>
                            )}
                          >
                            <Form.Item label="Name" name={[field.name, 'name']} rules={[{ required: true, message: 'Please enter a destination name' }]}>
                              <Input placeholder="Destination name" />
                            </Form.Item>

                            <Form.Item label="Enabled" name={[field.name, 'enabled']} valuePropName="checked">
                              <Switch />
                            </Form.Item>

                            <Form.Item label="Schema" name={[field.name, 'schema']} rules={[{ required: true, message: 'Please select a destination schema' }]}>
                              <Radio.Group buttonStyle="solid">
                                <Radio.Button value="SRT">SRT</Radio.Button>
                                <Radio.Button value="UDP">UDP</Radio.Button>
                              </Radio.Group>
                            </Form.Item>

                            <Form.Item noStyle shouldUpdate>
                              {({ getFieldValue }) => {
                                const schema = getFieldValue(['destinations', field.name, 'schema']);

                                if (schema === 'SRT') {
                                  return (
                                    <>
                                      <Form.Item
                                        label="Mode"
                                        name={[field.name, 'mode']}
                                        rules={[{ required: true, message: 'Please select an SRT mode' }]}
                                        extra="Caller: Actively initiates the connection. Listener: Waits for incoming connections. Rendezvous: Both endpoints connect to each other simultaneously."
                                      >
                                        <Radio.Group buttonStyle="solid">
                                          <Radio.Button value="caller">Caller</Radio.Button>
                                          <Radio.Button value="listener">Listener</Radio.Button>
                                          <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                                        </Radio.Group>
                                      </Form.Item>

                                      <Form.Item
                                        label="Interface"
                                        name={[field.name, 'interface_sys_name']}
                                        extra="Select a local interface to bind SRT socket to."
                                      >
                                        <Select allowClear loading={interfacesLoading} options={interfaceOptions} placeholder="Select interface" />
                                      </Form.Item>

                                      <Form.Item noStyle dependencies={[[field.name, 'mode']]}>
                                        {({ getFieldValue: getNestedFieldValue }) => {
                                          const mode = getNestedFieldValue(['destinations', field.name, 'mode']);
                                          const isCaller = mode === 'caller';
                                          const isRendezvous = mode === 'rendezvous';
                                          const showRemote = isCaller || isRendezvous;
                                          const showBind = !isCaller || isRendezvous;

                                          return (
                                            <>
                                              <Form.Item
                                                label="Remote Address"
                                                name={[field.name, 'address']}
                                                hidden={!showRemote}
                                                preserve
                                                rules={showRemote ? [{ required: true, message: 'Please enter a remote address' }] : []}
                                                extra={isRendezvous ? 'Remote host/IP of the rendezvous peer.' : 'Remote host/IP for caller mode.'}
                                              >
                                                <Input placeholder="Enter remote address" />
                                              </Form.Item>

                                              <Form.Item
                                                label="Bind Address"
                                                name={[field.name, 'localaddress']}
                                                hidden={!showBind}
                                                preserve
                                                rules={showBind ? [{ required: true, message: 'Please enter a bind address' }] : []}
                                                extra={isRendezvous ? 'Local address to bind before connecting to the rendezvous peer.' : 'Local address to bind.'}
                                              >
                                                <Input placeholder="Enter bind address" />
                                              </Form.Item>
                                            </>
                                          );
                                        }}
                                      </Form.Item>

                                      <Form.Item noStyle dependencies={[[field.name, 'mode']]}>
                                        {({ getFieldValue: getNestedFieldValue }) => {
                                          const mode = getNestedFieldValue(['destinations', field.name, 'mode']);
                                          const isCaller = mode === 'caller';
                                          const isRendezvous = mode === 'rendezvous';
                                          const showRemote = isCaller || isRendezvous;
                                          const showBind = !isCaller || isRendezvous;

                                          return (
                                            <>
                                              <Form.Item
                                                label="Remote Port"
                                                name={[field.name, 'port']}
                                                hidden={!showRemote}
                                                preserve
                                                extra="Remote port for caller/rendezvous mode."
                                                rules={showRemote
                                                  ? [
                                                      { required: true, message: 'Please enter a remote port' },
                                                      { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                                    ]
                                                  : []}
                                              >
                                                <InputNumber style={{ width: 150 }} placeholder="Enter remote port" />
                                              </Form.Item>

                                              <Form.Item
                                                label="Bind Port"
                                                name={[field.name, 'localport']}
                                                hidden={!showBind}
                                                preserve
                                                extra="Local port to bind."
                                                rules={showBind
                                                  ? [
                                                      { required: true, message: 'Please enter a bind port' },
                                                      { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                                    ]
                                                  : []}
                                              >
                                                <InputNumber style={{ width: 150 }} placeholder="Enter bind port" />
                                              </Form.Item>
                                            </>
                                          );
                                        }}
                                      </Form.Item>

                                      <Form.Item
                                        label="Latency, ms"
                                        name={[field.name, 'latency']}
                                        extra="The maximum accepted transmission latency in milliseconds"
                                      >
                                        <InputNumber style={{ width: 150 }} min={20} max={8000} placeholder="125" />
                                      </Form.Item>

                                      <Form.Item
                                        label="Authentication"
                                        name={[field.name, 'authentication']}
                                        valuePropName="checked"
                                        extra="Enable SRT authentication"
                                      >
                                        <Switch />
                                      </Form.Item>

                                      <Form.Item noStyle shouldUpdate>
                                        {({ getFieldValue: getNestedFieldValue }) =>
                                          getNestedFieldValue(['destinations', field.name, 'authentication']) && (
                                            <>
                                              <Form.Item
                                                label="Passphrase"
                                                name={[field.name, 'passphrase']}
                                                rules={[{ required: true, message: 'Please enter an SRT passphrase' }]}
                                                extra="Encryption passphrase for SRT authentication"
                                              >
                                                <Input.Password placeholder="Enter passphrase" />
                                              </Form.Item>

                                              <Form.Item
                                                label="Key Length"
                                                name={[field.name, 'pbkeylen']}
                                                rules={[{ required: true, message: 'Please select an SRT key length' }]}
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
                                                  style={{ width: 150 }}
                                                />
                                              </Form.Item>
                                            </>
                                          )
                                        }
                                      </Form.Item>
                                    </>
                                  );
                                }

                                if (schema === 'UDP') {
                                  return (
                                    <>
                                      <Form.Item
                                        label="Interface"
                                        name={[field.name, 'interface_sys_name']}
                                        extra="Select a local interface for UDP bind/multicast settings."
                                      >
                                        <Select allowClear loading={interfacesLoading} options={interfaceOptions} placeholder="Select interface" />
                                      </Form.Item>

                                      <Form.Item
                                        label="Address"
                                        name={[field.name, 'host']}
                                        rules={[{ required: true, message: 'Please enter a UDP destination address' }]}
                                        extra="The host/IP/Multicast group to send the packets to"
                                      >
                                        <Input placeholder="Enter address" />
                                      </Form.Item>

                                      <Form.Item
                                        label="Port"
                                        name={[field.name, 'port']}
                                        rules={[
                                          { required: true, message: 'Please enter a UDP destination port' },
                                          { type: 'number', min: 1, max: 65535, message: 'Port must be between 1 and 65535' },
                                        ]}
                                        extra="The port to send the packets to"
                                      >
                                        <InputNumber style={{ width: 150 }} placeholder="Enter port number" />
                                      </Form.Item>
                                    </>
                                  );
                                }

                                return null;
                              }}
                            </Form.Item>
                          </Card>
                        ))}

                        <Button icon={<PlusOutlined />} onClick={() => add({ ...DEFAULT_DESTINATION, name: `Destination ${fields.length + 1}` })}>
                          Add Destination
                        </Button>
                      </Space>
                    )}
                  </Form.List>
                }

                <Row justify="end" style={{ marginTop: 24 }}>
                  <Space>
                    <Button icon={<ArrowLeftOutlined />} onClick={handleBack}>Back</Button>
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

export default RouteSourceEdit;
