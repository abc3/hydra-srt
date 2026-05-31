const ENDPOINT_OPTION_KEYS = [
  'mode',
  'interface_sys_name',
  'localaddress',
  'localport',
  'address',
  'port',
  'host',
  'latency',
  'authentication',
  'passphrase',
  'pbkeylen',
  'poll_timeout',
  'auto_reconnect',
  'keep_listening',
  'multicast_iface',
  'bind_address_option',
  'auto-reconnect',
  'keep-listening',
];

type EndpointValue = string | number | boolean | null | undefined;
export type EndpointRecord = Record<string, unknown> & {
  schema?: string;
  mode?: string;
  address?: EndpointValue;
  localaddress?: EndpointValue;
  host?: EndpointValue;
  port?: EndpointValue;
  localport?: EndpointValue;
  auto_reconnect?: EndpointValue;
  keep_listening?: EndpointValue;
  'auto-reconnect'?: EndpointValue;
  'keep-listening'?: EndpointValue;
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

export const normalizeEndpointForForm = (endpoint: EndpointRecord | null | undefined): EndpointRecord | null | undefined => {
  if (!endpoint) {
    return endpoint;
  }

  const flat = normalizeBooleanAliases({ ...endpoint });

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

  return flat;
};

export const flattenEndpointPayload = (endpoint: EndpointRecord | null | undefined): EndpointRecord | null | undefined => {
  if (!endpoint) {
    return endpoint;
  }

  return normalizeEndpointForForm(endpoint);
};
