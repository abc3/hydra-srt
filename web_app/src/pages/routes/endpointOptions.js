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

const toNumberIfPresent = (value) => {
  if (value === undefined || value === null || value === '') {
    return value;
  }

  const num = Number(value);
  return Number.isNaN(num) ? value : num;
};

const normalizeBooleanAliases = (options) => ({
  ...options,
  auto_reconnect: options.auto_reconnect ?? options['auto-reconnect'],
  keep_listening: options.keep_listening ?? options['keep-listening'],
});

export const getEndpointOption = (endpoint, key) => {
  if (!endpoint) {
    return undefined;
  }
  return endpoint[key];
};

export const normalizeEndpointForForm = (endpoint) => {
  if (!endpoint) {
    return endpoint;
  }

  const flat = normalizeBooleanAliases({ ...endpoint });

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

export const flattenEndpointPayload = (endpoint) => {
  if (!endpoint) {
    return endpoint;
  }

  return normalizeEndpointForForm(endpoint);
};
