import {
  NDI_BANDWIDTHS,
  NDI_COLOR_FORMATS,
  NDI_DEFAULT_CONNECT_TIMEOUT_MS,
  NDI_DEFAULT_MAX_QUEUE_LENGTH,
  NDI_DEFAULT_RECEIVE_TIMEOUT_MS,
  NDI_DEFAULT_TRACK_DISCOVERY_TIMEOUT_MS,
  NDI_MEDIA_POLICIES,
  NDI_SELECTION_MODES,
  NDI_SNAPSHOT_FIELDS,
  NDI_TIMESTAMP_MODES,
  NDI_TIMEOUT_MS_MAX,
  NDI_TIMEOUT_MS_MIN,
  NDI_MAX_QUEUE_LENGTH_MAX,
  NDI_MAX_QUEUE_LENGTH_MIN,
} from './ndiConstants';

type EndpointValue = string | number | boolean | null | undefined;
export type EndpointRecord = Record<string, unknown> & {
  schema?: string;
  mode?: string;
  interface_sys_name?: EndpointValue;
  address?: EndpointValue;
  localaddress?: EndpointValue;
  host?: EndpointValue;
  port?: EndpointValue;
  localport?: EndpointValue;
  program_number?: EndpointValue;
  auto_reconnect?: EndpointValue;
  keep_listening?: EndpointValue;
  streamid?: EndpointValue;
  multicast?: EndpointValue;
  multicast_iface?: EndpointValue;
  bind_address_option?: EndpointValue;
  path?: EndpointValue;
  location?: EndpointValue;
  'auto-reconnect'?: EndpointValue;
  'keep-listening'?: EndpointValue;
  ndi_selection_mode?: EndpointValue;
  ndi_source_name?: EndpointValue;
  ndi_source_address?: EndpointValue;
  ndi_receiver_name?: EndpointValue;
  ndi_media_policy?: EndpointValue;
  ndi_bandwidth?: EndpointValue;
  ndi_color_format?: EndpointValue;
  ndi_timestamp_mode?: EndpointValue;
  ndi_connect_timeout_ms?: EndpointValue;
  ndi_receive_timeout_ms?: EndpointValue;
  ndi_track_discovery_timeout_ms?: EndpointValue;
  ndi_max_queue_length?: EndpointValue;
  ndi_sender_name?: EndpointValue;
  selection_token?: EndpointValue;
};

const toNumberIfPresent = (value: EndpointValue): EndpointValue => {
  if (value === undefined || value === null || value === '') {
    return value;
  }

  const num = Number(value);
  return Number.isNaN(num) ? value : num;
};

const normalizeBooleanAliases = (options: EndpointRecord): EndpointRecord => ({
  ...options,
  auto_reconnect: options.auto_reconnect ?? options['auto-reconnect'],
  keep_listening: options.keep_listening ?? options['keep-listening'],
});

export const getEndpointOption = <T = unknown>(endpoint: EndpointRecord | null | undefined, key: string): T | undefined => {
  if (!endpoint) {
    return undefined;
  }
  return endpoint[key] as T | undefined;
};

const normalizeIpAccessList = (value: unknown): string[] => {
  if (Array.isArray(value)) {
    return [...new Set(value.map((item) => String(item).trim()).filter(Boolean))];
  }

  if (typeof value === 'string') {
    return [...new Set(value.split(/[\n,]+/).map((item) => item.trim()).filter(Boolean))];
  }

  return [];
};

const clampNdiTimeout = (value: EndpointValue, fallback: number): number => {
  const num = Number(value);
  if (!Number.isFinite(num)) {
    return fallback;
  }
  return Math.min(NDI_TIMEOUT_MS_MAX, Math.max(NDI_TIMEOUT_MS_MIN, Math.trunc(num)));
};

const clampNdiQueue = (value: EndpointValue, fallback: number): number => {
  const num = Number(value);
  if (!Number.isFinite(num)) {
    return fallback;
  }
  return Math.min(NDI_MAX_QUEUE_LENGTH_MAX, Math.max(NDI_MAX_QUEUE_LENGTH_MIN, Math.trunc(num)));
};

const allowlistOrNull = <T extends string>(value: EndpointValue, allowlist: readonly T[]): T | null => {
  if (typeof value !== 'string' || value === '') {
    return null;
  }
  return (allowlist as readonly string[]).includes(value) ? (value as T) : null;
};

const normalizeNdiEndpoint = (flat: EndpointRecord): EndpointRecord => {
  if (flat.schema !== 'NDI') {
    return flat;
  }

  // Selection tokens are never persisted endpoint state.
  delete flat.selection_token;
  for (const key of NDI_SNAPSHOT_FIELDS) {
    // Keep snapshots for display conflict UI; strip on flatten/save instead.
    if (flat[key] === undefined) {
      flat[key] = null;
    }
  }

  const mode = allowlistOrNull(flat.ndi_selection_mode, NDI_SELECTION_MODES);
  flat.ndi_selection_mode = mode ?? 'discovery_name';

  if (flat.ndi_selection_mode === 'discovery_name') {
    flat.ndi_source_address = null;
  } else {
    flat.ndi_source_name = null;
  }

  flat.ndi_media_policy =
    allowlistOrNull(flat.ndi_media_policy, NDI_MEDIA_POLICIES) ?? 'video_and_audio_required';
  flat.ndi_bandwidth = allowlistOrNull(flat.ndi_bandwidth, NDI_BANDWIDTHS) ?? 'highest';
  flat.ndi_color_format = allowlistOrNull(flat.ndi_color_format, NDI_COLOR_FORMATS) ?? 'uyvy-bgra';
  const timestampMode = allowlistOrNull(flat.ndi_timestamp_mode, NDI_TIMESTAMP_MODES);
  flat.ndi_timestamp_mode = timestampMode;

  if (flat.ndi_connect_timeout_ms == null || flat.ndi_connect_timeout_ms === '') {
    flat.ndi_connect_timeout_ms = NDI_DEFAULT_CONNECT_TIMEOUT_MS;
  } else {
    flat.ndi_connect_timeout_ms = clampNdiTimeout(
      flat.ndi_connect_timeout_ms,
      NDI_DEFAULT_CONNECT_TIMEOUT_MS,
    );
  }
  if (flat.ndi_receive_timeout_ms == null || flat.ndi_receive_timeout_ms === '') {
    flat.ndi_receive_timeout_ms = NDI_DEFAULT_RECEIVE_TIMEOUT_MS;
  } else {
    flat.ndi_receive_timeout_ms = clampNdiTimeout(
      flat.ndi_receive_timeout_ms,
      NDI_DEFAULT_RECEIVE_TIMEOUT_MS,
    );
  }
  if (flat.ndi_track_discovery_timeout_ms == null || flat.ndi_track_discovery_timeout_ms === '') {
    flat.ndi_track_discovery_timeout_ms = NDI_DEFAULT_TRACK_DISCOVERY_TIMEOUT_MS;
  } else {
    flat.ndi_track_discovery_timeout_ms = clampNdiTimeout(
      flat.ndi_track_discovery_timeout_ms,
      NDI_DEFAULT_TRACK_DISCOVERY_TIMEOUT_MS,
    );
  }
  if (flat.ndi_max_queue_length == null || flat.ndi_max_queue_length === '') {
    flat.ndi_max_queue_length = NDI_DEFAULT_MAX_QUEUE_LENGTH;
  } else {
    flat.ndi_max_queue_length = clampNdiQueue(
      flat.ndi_max_queue_length,
      NDI_DEFAULT_MAX_QUEUE_LENGTH,
    );
  }

  if (typeof flat.ndi_sender_name === 'string') {
    flat.ndi_sender_name = flat.ndi_sender_name.trim();
  }
  if (typeof flat.ndi_source_name === 'string') {
    flat.ndi_source_name = flat.ndi_source_name.trim();
  }
  if (typeof flat.ndi_source_address === 'string') {
    flat.ndi_source_address = flat.ndi_source_address.trim();
  }
  if (typeof flat.ndi_receiver_name === 'string') {
    flat.ndi_receiver_name = flat.ndi_receiver_name.trim() || null;
  }

  return flat;
};

const stripNdiClientOwnedFields = (flat: EndpointRecord): EndpointRecord => {
  if (flat.schema !== 'NDI') {
    return flat;
  }

  const next = { ...flat };
  for (const key of NDI_SNAPSHOT_FIELDS) {
    delete next[key];
  }

  // Transient selection token is submitted only when freshly chosen.
  if (next.selection_token === undefined || next.selection_token === null || next.selection_token === '') {
    delete next.selection_token;
  }

  if (next.ndi_selection_mode === 'discovery_name') {
    next.ndi_source_address = null;
  } else if (next.ndi_selection_mode === 'direct_address') {
    next.ndi_source_name = null;
    delete next.selection_token;
  }

  return next;
};

export const normalizeEndpointForForm = (endpoint: EndpointRecord | null | undefined): EndpointRecord | null | undefined => {
  if (!endpoint) {
    return endpoint;
  }

  const flat = normalizeBooleanAliases({ ...endpoint });

  if (
    Object.prototype.hasOwnProperty.call(flat, 'interface_sys_name') &&
    flat.interface_sys_name === undefined
  ) {
    flat.interface_sys_name = null;
  }

  // Backward compatibility: legacy SRT records may still persist remote peer in `host`
  // (historically from schema_options JSON) while the current form uses `address`.
  if (
    flat.schema === 'SRT' &&
    (flat.address === undefined || flat.address === null || flat.address === '') &&
    typeof flat.host === 'string' &&
    flat.host !== ''
  ) {
    flat.address = flat.host;
  }

  if (
    (flat.schema === 'UDP' || flat.schema === 'RTP') &&
    (flat.address === undefined || flat.address === null || flat.address === '') &&
    typeof flat.host === 'string' &&
    flat.host !== ''
  ) {
    flat.address = flat.host;
  }

  if (
    flat.schema === 'SRT' &&
    flat.mode === 'caller' &&
    (flat.address === undefined || flat.address === null || flat.address === '') &&
    typeof flat.localaddress === 'string' &&
    flat.localaddress !== ''
  ) {
    flat.address = flat.localaddress;
  }

  if (
    flat.schema === 'SRT' &&
    flat.mode === 'caller' &&
    (flat.port === undefined || flat.port === null || flat.port === '') &&
    flat.localport !== undefined &&
    flat.localport !== null &&
    flat.localport !== ''
  ) {
    flat.port = flat.localport;
  }

  flat.port = toNumberIfPresent(flat.port);
  flat.localport = toNumberIfPresent(flat.localport);
  if (flat.schema === 'UDP' || flat.schema === 'RTP' || flat.schema === 'SRT') {
    flat.program_number = toNumberIfPresent(flat.program_number);
  } else {
    delete flat.program_number;
  }
  flat.multicast = flat.multicast ?? false;
  flat.allowed_list = normalizeIpAccessList(flat.allowed_list);
  flat.denied_list = normalizeIpAccessList(flat.denied_list);
  flat.limit_access = flat.limit_access ?? false;

  return normalizeNdiEndpoint(flat);
};

export const flattenEndpointPayload = (endpoint: EndpointRecord | null | undefined): EndpointRecord | null | undefined => {
  if (!endpoint) {
    return endpoint;
  }

  const selectionToken =
    typeof endpoint.selection_token === 'string' && endpoint.selection_token !== ''
      ? endpoint.selection_token
      : undefined;

  const withoutToken = { ...endpoint };
  delete withoutToken.selection_token;
  const normalized = normalizeEndpointForForm(withoutToken);
  if (!normalized) {
    return normalized;
  }

  if (selectionToken) {
    normalized.selection_token = selectionToken;
  }

  if (
    normalized.schema !== 'UDP' &&
    normalized.schema !== 'RTP' &&
    normalized.schema !== 'SRT'
  ) {
    delete normalized.program_number;
  } else if (
    normalized.program_number === undefined ||
    normalized.program_number === null ||
    normalized.program_number === ''
  ) {
    delete normalized.program_number;
  }

  return stripNdiClientOwnedFields(normalized);
};
