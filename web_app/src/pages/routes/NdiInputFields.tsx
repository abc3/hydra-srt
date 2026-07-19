import {
  Button,
  Collapse,
  Form,
  Input,
  InputNumber,
  Radio,
  Select,
  Space,
  Spin,
  Typography,
  message,
} from 'antd';
import { ReloadOutlined, ExperimentOutlined } from '@ant-design/icons';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { NdiCapabilities, NdiProbeResult, NdiSourceRow, NdiSourcesMeta } from '../../types/ndi';
import type { AppError } from '../../types/errors';
import { getErrorMessage } from '../../types/errors';
import { ndiApi } from '../../utils/ndiApi';
import NdiCapabilityAlert from './NdiCapabilityAlert';
import NdiTrademarkNotice from './NdiTrademarkNotice';
import {
  NDI_BANDWIDTHS,
  NDI_COLOR_FORMATS,
  NDI_DEFAULT_CONNECT_TIMEOUT_MS,
  NDI_DEFAULT_MAX_QUEUE_LENGTH,
  NDI_DEFAULT_RECEIVE_TIMEOUT_MS,
  NDI_DEFAULT_TRACK_DISCOVERY_TIMEOUT_MS,
  NDI_MAX_QUEUE_LENGTH_MAX,
  NDI_MAX_QUEUE_LENGTH_MIN,
  NDI_MEDIA_POLICIES,
  NDI_TIMESTAMP_MODES,
  NDI_TIMEOUT_MS_MAX,
  NDI_TIMEOUT_MS_MIN,
} from './ndiConstants';
import { isNdiRunnable } from './ndiCapabilityState';

const { Text } = Typography;

type ListName = 'sources' | 'destinations';

type Props = {
  /** Form.List field index when nested under RouteSourceEdit. */
  namePrefix?: number;
  listName?: ListName;
  capabilities: NdiCapabilities | null;
  capabilitiesLoading?: boolean;
  endpointId?: string;
  /** Saved discovery identity for conflict display. */
  savedSourceName?: string | null;
  savedObservedAddress?: string | null;
  savedObservedName?: string | null;
};

const fieldName = (namePrefix: number | undefined, key: string) =>
  namePrefix === undefined ? key : [namePrefix, key];

const fieldPath = (listName: ListName | undefined, namePrefix: number | undefined, key: string) => {
  if (namePrefix === undefined) {
    return key;
  }
  return [listName ?? 'sources', namePrefix, key];
};

const optionLabels = (values: readonly string[]) =>
  values.map((value) => ({ label: value, value }));

const NdiInputFields = ({
  namePrefix,
  listName = 'sources',
  capabilities,
  capabilitiesLoading = false,
  endpointId,
  savedSourceName,
  savedObservedAddress,
  savedObservedName,
}: Props) => {
  const form = Form.useFormInstance();
  const [messageApi, contextHolder] = message.useMessage();
  const [sources, setSources] = useState<NdiSourceRow[]>([]);
  const [meta, setMeta] = useState<NdiSourcesMeta | null>(null);
  const [scanLoading, setScanLoading] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [search, setSearch] = useState('');
  const [probeLoading, setProbeLoading] = useState(false);
  const [probeResult, setProbeResult] = useState<NdiProbeResult | null>(null);
  const [announce, setAnnounce] = useState('');
  const searchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const liveRef = useRef<HTMLDivElement | null>(null);

  const selectionMode = Form.useWatch(fieldPath(listName, namePrefix, 'ndi_selection_mode'), form)
    ?? 'discovery_name';
  const selectionToken = Form.useWatch(fieldPath(listName, namePrefix, 'selection_token'), form);
  const runnable = isNdiRunnable(capabilities, 'receive');
  const discoveryOk = isNdiRunnable(capabilities, 'discovery');
  const directOk = isNdiRunnable(capabilities, 'direct_address');

  const loadSources = useCallback(async (opts: { refresh?: boolean; q?: string } = {}) => {
    if (!capabilities?.feature_enabled) {
      return;
    }
    setScanLoading(true);
    setAnnounce(opts.refresh ? 'Refreshing NDI discovery…' : 'Loading discovered NDI sources…');
    try {
      const response = await ndiApi.listSources({
        refresh: opts.refresh === true,
        q: opts.q,
      });
      setSources(Array.isArray(response.data) ? response.data : []);
      setMeta(response.meta ?? null);
      const count = response.meta?.result_count ?? response.data?.length ?? 0;
      setAnnounce(
        response.meta?.refresh_in_progress
          ? 'NDI scan in progress. Results may still be incomplete.'
          : `Found ${count} NDI source${count === 1 ? '' : 's'}.`,
      );
    } catch (error) {
      const err = error as AppError;
      const code = typeof err.payload === 'object' && err.payload && 'code' in err.payload
        ? String((err.payload as { code?: string }).code)
        : undefined;
      setAnnounce(code ? `Discovery failed (${code}).` : getErrorMessage(error, 'Discovery failed'));
      messageApi.error(getErrorMessage(error, 'Failed to load NDI sources'));
    } finally {
      setScanLoading(false);
    }
  }, [capabilities?.feature_enabled, messageApi]);

  useEffect(() => {
    if (selectionMode === 'discovery_name' && capabilities?.feature_enabled) {
      void loadSources({ q: search || undefined });
    }
  }, [selectionMode, capabilities?.feature_enabled]); // eslint-disable-line react-hooks/exhaustive-deps

  const handleSearchChange = (value: string) => {
    setSearch(value);
    if (searchTimer.current) {
      clearTimeout(searchTimer.current);
    }
    searchTimer.current = setTimeout(() => {
      void loadSources({ q: value || undefined });
    }, 300);
  };

  const handleRefresh = async () => {
    if (refreshing) {
      return;
    }
    setRefreshing(true);
    setAnnounce('Requesting NDI discovery refresh…');
    try {
      await ndiApi.refreshDiscovery();
      await loadSources({ refresh: false, q: search || undefined });
    } catch (error) {
      messageApi.error(getErrorMessage(error, 'Failed to refresh discovery'));
      setAnnounce(getErrorMessage(error, 'Refresh failed'));
    } finally {
      setRefreshing(false);
    }
  };

  const handleSelectSource = (token: string) => {
    const row = sources.find((item) => item.selection_token === token);
    if (namePrefix === undefined) {
      form.setFieldsValue({
        selection_token: token,
        ndi_selection_mode: 'discovery_name',
        ndi_source_name: row?.name ?? undefined,
        ndi_source_address: null,
      });
      return;
    }

    form.setFieldValue([listName, namePrefix, 'selection_token'], token);
    form.setFieldValue([listName, namePrefix, 'ndi_selection_mode'], 'discovery_name');
    form.setFieldValue([listName, namePrefix, 'ndi_source_name'], row?.name ?? undefined);
    form.setFieldValue([listName, namePrefix, 'ndi_source_address'], null);
  };

  const handleProbe = async () => {
    if (probeLoading || !runnable) {
      return;
    }
    setProbeLoading(true);
    setProbeResult(null);
    setAnnounce('Testing NDI input…');
    try {
      const values = form.getFieldsValue(true);
      const endpointValues =
        namePrefix === undefined
          ? values
          : (values?.[listName]?.[namePrefix] ?? {});

      const body = endpointId
        ? { endpoint_id: endpointId }
        : {
            endpoint: {
              schema: 'NDI',
              type: 'source',
              name: endpointValues.name || 'probe',
              ndi_selection_mode: endpointValues.ndi_selection_mode,
              ndi_source_name: endpointValues.ndi_source_name,
              ndi_source_address: endpointValues.ndi_source_address,
              selection_token: endpointValues.selection_token,
              ndi_receiver_name: endpointValues.ndi_receiver_name,
              ndi_media_policy: endpointValues.ndi_media_policy,
              ndi_bandwidth: endpointValues.ndi_bandwidth,
              ndi_color_format: endpointValues.ndi_color_format,
              ndi_timestamp_mode: endpointValues.ndi_timestamp_mode,
              ndi_connect_timeout_ms: endpointValues.ndi_connect_timeout_ms,
              ndi_receive_timeout_ms: endpointValues.ndi_receive_timeout_ms,
              ndi_track_discovery_timeout_ms: endpointValues.ndi_track_discovery_timeout_ms,
              ndi_max_queue_length: endpointValues.ndi_max_queue_length,
            },
          };

      const response = await ndiApi.probe(body);
      setProbeResult(response.data ?? null);
      setAnnounce(
        response.data?.ok
          ? 'NDI input probe succeeded.'
          : `NDI input probe failed${response.data?.code ? ` (${response.data.code})` : ''}.`,
      );
    } catch (error) {
      const err = error as AppError;
      if (err.errors && typeof err.errors === 'object') {
        const firstKey = Object.keys(err.errors as Record<string, unknown>)[0];
        if (firstKey) {
          form.scrollToField(fieldName(namePrefix, firstKey));
        }
      }
      messageApi.error(getErrorMessage(error, 'NDI probe failed'));
      setAnnounce(getErrorMessage(error, 'NDI probe failed'));
    } finally {
      setProbeLoading(false);
    }
  };

  const sourceOptions = useMemo(
    () =>
      sources.map((row) => ({
        value: row.selection_token,
        label: `${row.display_name || row.name}${row.url_address ? ` · ${row.url_address}` : ''}${row.stale ? ' · stale' : ''}`,
      })),
    [sources],
  );

  const conflict =
    savedSourceName &&
    selectionToken &&
    sources.length > 0 &&
    !sources.some((row) => row.selection_token === selectionToken && row.name === savedSourceName);

  const snapshotConflict =
    Boolean(savedObservedName || savedObservedAddress) &&
    Boolean(savedSourceName) &&
    sources.some((row) => row.name === savedSourceName && row.url_address && row.url_address !== savedObservedAddress);

  return (
    <>
      {contextHolder}
      <div ref={liveRef} aria-live="polite" aria-atomic="true" className="sr-only" style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden' }}>
        {announce}
      </div>

      <NdiCapabilityAlert
        capabilities={capabilities}
        loading={capabilitiesLoading}
        direction="receive"
      />

      <Form.Item
        label="Selection mode"
        name={fieldName(namePrefix, 'ndi_selection_mode')}
        initialValue="discovery_name"
        rules={[{ required: true, message: 'Please select an NDI selection mode' }]}
      >
        <Radio.Group buttonStyle="solid" style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
          <Radio.Button value="discovery_name">Discover by name</Radio.Button>
          <Radio.Button value="direct_address">Direct address</Radio.Button>
        </Radio.Group>
      </Form.Item>

      {selectionMode === 'discovery_name' && (
        <>
          <Space wrap style={{ width: '100%', marginBottom: 12 }}>
            <Input
              allowClear
              placeholder="Search discovered sources"
              value={search}
              onChange={(event) => handleSearchChange(event.target.value)}
              style={{ minWidth: 220 }}
              aria-label="Search NDI sources"
            />
            <Button
              icon={<ReloadOutlined />}
              onClick={() => void handleRefresh()}
              loading={refreshing}
              disabled={!discoveryOk || refreshing}
              style={{ minWidth: 44 }}
            >
              Refresh
            </Button>
          </Space>

          {(scanLoading || meta?.refresh_in_progress) && (
            <Space style={{ marginBottom: 8 }} aria-live="polite">
              <Spin size="small" />
              <Text type="secondary">
                {meta?.refresh_in_progress
                  ? 'Scan in progress — list may still be incomplete.'
                  : 'Loading discovery results…'}
              </Text>
            </Space>
          )}

          {meta?.scanned_at && (
            <Text type="secondary" style={{ display: 'block', marginBottom: 8 }}>
              Generation {meta.generation} · scanned {new Date(meta.scanned_at).toLocaleString()}
              {meta.truncated ? ' · truncated' : ''}
            </Text>
          )}

          {meta?.duplicate_name_groups?.length ? (
            <Text type="secondary" style={{ display: 'block', marginBottom: 8, color: '#d48806' }}>
              Duplicate sender names detected in this generation. Prefer a unique selection or direct address.
            </Text>
          ) : null}

          <Form.Item name={fieldName(namePrefix, 'selection_token')} hidden>
            <Input />
          </Form.Item>
          <Form.Item name={fieldName(namePrefix, 'ndi_source_name')} hidden>
            <Input />
          </Form.Item>

          <Form.Item
            label="Discovered source"
            required
            rules={[
              {
                validator: async () => {
                  const token = form.getFieldValue(fieldPath(listName, namePrefix, 'selection_token'));
                  const name = form.getFieldValue(fieldPath(listName, namePrefix, 'ndi_source_name'));
                  if (!token && !name) {
                    throw new Error('Select a discovered NDI source');
                  }
                },
              },
            ]}
            extra="Selection is keyed by an opaque snapshot token. Hydra persists server-resolved identity; do not invent snapshot fields."
          >
            <Select
              showSearch
              optionFilterProp="label"
              placeholder={discoveryOk ? 'Select an NDI source' : 'Discovery unavailable — use direct address'}
              options={sourceOptions}
              value={selectionToken || undefined}
              onChange={handleSelectSource}
              disabled={!discoveryOk && !savedSourceName}
              loading={scanLoading}
              listHeight={280}
              style={{ width: '100%' }}
              aria-label="Discovered NDI sources"
              notFoundContent={scanLoading ? <Spin size="small" /> : 'No sources found'}
            />
          </Form.Item>

          {savedSourceName && (
            <Text type="secondary" style={{ display: 'block', marginBottom: 8 }}>
              Saved identity: {savedSourceName}
              {savedObservedAddress ? ` @ ${savedObservedAddress}` : ''}
            </Text>
          )}

          {(conflict || snapshotConflict) && (
            <Text type="secondary" style={{ display: 'block', marginBottom: 8, color: '#d48806' }}>
              Current discovery snapshot differs from the saved identity. Keep the saved selection or deliberately pick a new source.
            </Text>
          )}
        </>
      )}

      {selectionMode === 'direct_address' && (
        <Form.Item
          label="Direct address"
          name={fieldName(namePrefix, 'ndi_source_address')}
          rules={[
            { required: true, message: 'Enter host:port (IPv4) or [IPv6]:port' },
            {
              pattern: /^(\[[0-9a-fA-F:]+\]:\d{1,5}|(\d{1,3}\.){3}\d{1,3}:\d{1,5})$/,
              message: 'Use IPv4 host:port or [IPv6]:port',
            },
          ]}
          extra="Subject to node network policy. Direct address can work when mDNS discovery is unavailable."
        >
          <Input placeholder="192.0.2.10:5961" disabled={!directOk && !form.getFieldValue(fieldPath(listName, namePrefix, 'ndi_source_address'))} />
        </Form.Item>
      )}

      <Form.Item
        label="Receiver name"
        name={fieldName(namePrefix, 'ndi_receiver_name')}
        extra="Optional NDI receiver display name for this route."
      >
        <Input placeholder="Hydra route name" />
      </Form.Item>

      <Form.Item
        label="Media policy"
        name={fieldName(namePrefix, 'ndi_media_policy')}
        initialValue="video_and_audio_required"
        rules={[{ required: true, message: 'Select a media policy' }]}
      >
        <Select options={optionLabels(NDI_MEDIA_POLICIES)} />
      </Form.Item>

      <Collapse
        items={[{
          key: 'advanced',
          label: 'Advanced receive settings',
          children: (
            <>
              <Form.Item label="Bandwidth" name={fieldName(namePrefix, 'ndi_bandwidth')} initialValue="highest">
                <Select options={optionLabels(NDI_BANDWIDTHS)} />
              </Form.Item>
              <Form.Item label="Color format" name={fieldName(namePrefix, 'ndi_color_format')} initialValue="uyvy-bgra">
                <Select options={optionLabels(NDI_COLOR_FORMATS)} />
              </Form.Item>
              <Form.Item label="Timestamp mode" name={fieldName(namePrefix, 'ndi_timestamp_mode')}>
                <Select allowClear options={optionLabels(NDI_TIMESTAMP_MODES)} placeholder="Optional" />
              </Form.Item>
              <Form.Item
                label="Connect timeout (ms)"
                name={fieldName(namePrefix, 'ndi_connect_timeout_ms')}
                initialValue={NDI_DEFAULT_CONNECT_TIMEOUT_MS}
                rules={[{ type: 'number', min: NDI_TIMEOUT_MS_MIN, max: NDI_TIMEOUT_MS_MAX }]}
              >
                <InputNumber style={{ width: 160 }} min={NDI_TIMEOUT_MS_MIN} max={NDI_TIMEOUT_MS_MAX} />
              </Form.Item>
              <Form.Item
                label="Receive timeout (ms)"
                name={fieldName(namePrefix, 'ndi_receive_timeout_ms')}
                initialValue={NDI_DEFAULT_RECEIVE_TIMEOUT_MS}
                rules={[{ type: 'number', min: NDI_TIMEOUT_MS_MIN, max: NDI_TIMEOUT_MS_MAX }]}
              >
                <InputNumber style={{ width: 160 }} min={NDI_TIMEOUT_MS_MIN} max={NDI_TIMEOUT_MS_MAX} />
              </Form.Item>
              <Form.Item
                label="Track discovery timeout (ms)"
                name={fieldName(namePrefix, 'ndi_track_discovery_timeout_ms')}
                initialValue={NDI_DEFAULT_TRACK_DISCOVERY_TIMEOUT_MS}
                rules={[{ type: 'number', min: NDI_TIMEOUT_MS_MIN, max: NDI_TIMEOUT_MS_MAX }]}
              >
                <InputNumber style={{ width: 160 }} min={NDI_TIMEOUT_MS_MIN} max={NDI_TIMEOUT_MS_MAX} />
              </Form.Item>
              <Form.Item
                label="Max queue length"
                name={fieldName(namePrefix, 'ndi_max_queue_length')}
                initialValue={NDI_DEFAULT_MAX_QUEUE_LENGTH}
                rules={[{ type: 'number', min: NDI_MAX_QUEUE_LENGTH_MIN, max: NDI_MAX_QUEUE_LENGTH_MAX }]}
              >
                <InputNumber style={{ width: 160 }} min={NDI_MAX_QUEUE_LENGTH_MIN} max={NDI_MAX_QUEUE_LENGTH_MAX} />
              </Form.Item>
            </>
          ),
        }]}
        style={{ marginBottom: 16 }}
      />

      <Space wrap style={{ marginBottom: 8 }}>
        <Button
          icon={<ExperimentOutlined />}
          onClick={() => void handleProbe()}
          loading={probeLoading}
          disabled={!runnable || probeLoading}
         
        >
          Test input
        </Button>
      </Space>

      {probeResult && (
        <Text style={{ display: 'block', marginBottom: 8 }} aria-live="polite">
          Probe {probeResult.ok ? 'ok' : 'failed'}
          {probeResult.code ? ` · ${probeResult.code}` : ''}
          {probeResult.detail ? ` · ${probeResult.detail}` : ''}
          {probeResult.elapsed_ms != null ? ` · ${probeResult.elapsed_ms} ms` : ''}
        </Text>
      )}

      <NdiTrademarkNotice />
    </>
  );
};

export default NdiInputFields;
