import type {
  NdiCapabilities,
  NdiCapabilityUiState,
  NdiReasonCode,
} from '../../types/ndi';

export type NdiDirection = 'receive' | 'send' | 'discovery' | 'direct_address';

const PRIMARY_REASON_PRIORITY: NdiReasonCode[] = [
  'NDI_DISABLED',
  'NDI_LEGAL_GATE_DISABLED',
  'NDI_PLATFORM_UNSUPPORTED',
  'NDI_CPU_UNSUPPORTED',
  'NDI_PLUGIN_MISSING',
  'NDI_RUNTIME_MISSING',
  'NDI_RUNTIME_INCOMPATIBLE',
  'NDI_HELPER_PENDING',
  'NDI_HELPER_UNHEALTHY',
  'NDI_AVAHI_UNAVAILABLE',
  'NDI_DISCOVERY_UNAVAILABLE',
];

export const collectReasonCodes = (
  capabilities: NdiCapabilities | null | undefined,
  direction: NdiDirection = 'receive',
): NdiReasonCode[] => {
  if (!capabilities) {
    return [];
  }

  const gate =
    direction === 'send'
      ? capabilities.send
      : direction === 'discovery'
        ? capabilities.discovery
        : direction === 'direct_address'
          ? capabilities.direct_address
          : capabilities.receive;

  return Array.isArray(gate?.reason_codes) ? gate.reason_codes : [];
};

export const primaryReasonCode = (reasons: NdiReasonCode[]): NdiReasonCode | null => {
  for (const code of PRIMARY_REASON_PRIORITY) {
    if (reasons.includes(code)) {
      return code;
    }
  }
  return reasons[0] ?? null;
};

export const reasonCodeExplanation = (code: NdiReasonCode | null | undefined): string => {
  switch (code) {
    case 'NDI_DISABLED':
    case 'NDI_LEGAL_GATE_DISABLED':
      return 'NDI is turned off on this server. Set NDI_FEATURE=true and restart to enable it.';
    case 'NDI_PLUGIN_MISSING':
      return "The NDI GStreamer plugin is not installed on this server.";
    case 'NDI_RUNTIME_MISSING':
      return 'The NDI runtime is not installed on this server. You can still save these settings.';
    case 'NDI_RUNTIME_INCOMPATIBLE':
      return 'The NDI runtime installed on this server is not supported by this build.';
    case 'NDI_PLATFORM_UNSUPPORTED':
      return "This server's operating system does not support NDI in this build.";
    case 'NDI_CPU_UNSUPPORTED':
      return "This server's CPU is not supported for NDI in this build.";
    case 'NDI_AVAHI_UNAVAILABLE':
      return 'Automatic discovery is unavailable because Avahi is not running. You can still enter a source address directly.';
    case 'NDI_DISCOVERY_UNAVAILABLE':
      return 'Automatic discovery is unavailable. Enter the source address directly, or try again shortly.';
    case 'NDI_HELPER_PENDING':
      return 'NDI is still starting up. Discovery will be available in a moment.';
    case 'NDI_HELPER_UNHEALTHY':
      return 'HydraSRT could not start NDI on this server. Check that the NDI runtime is installed correctly.';
    case null:
    case undefined:
      return 'NDI is not ready on this server yet.';
    default:
      return `NDI is unavailable (${code}).`;
  }
};

export const deriveNdiCapabilityUiState = (
  capabilities: NdiCapabilities | null | undefined,
  options: { loading?: boolean; direction?: NdiDirection } = {},
): NdiCapabilityUiState => {
  if (options.loading || !capabilities) {
    return 'checking';
  }

  if (!capabilities.feature_enabled) {
    return 'feature-disabled';
  }

  if (capabilities.check_in_progress) {
    return 'helper-restarting';
  }

  if (capabilities.stale) {
    return 'stale';
  }

  const reasons = collectReasonCodes(capabilities, options.direction ?? 'receive');
  const primary = primaryReasonCode(reasons);

  if (!primary) {
    const gateAvailable =
      options.direction === 'send'
        ? capabilities.send.available
        : options.direction === 'discovery'
          ? capabilities.discovery.available
          : options.direction === 'direct_address'
            ? capabilities.direct_address.available
            : capabilities.receive.available;

    return gateAvailable ? 'available' : 'runtime-missing-or-incompatible';
  }

  switch (primary) {
    case 'NDI_DISABLED':
    case 'NDI_LEGAL_GATE_DISABLED':
      return 'feature-disabled';
    case 'NDI_PLUGIN_MISSING':
      return 'plugin-missing';
    case 'NDI_RUNTIME_MISSING':
    case 'NDI_RUNTIME_INCOMPATIBLE':
      return 'runtime-missing-or-incompatible';
    case 'NDI_PLATFORM_UNSUPPORTED':
    case 'NDI_CPU_UNSUPPORTED':
      return 'platform-CPU-unsupported';
    case 'NDI_AVAHI_UNAVAILABLE':
    case 'NDI_DISCOVERY_UNAVAILABLE':
      return 'discovery-prerequisite-unavailable';
    case 'NDI_HELPER_PENDING':
    case 'NDI_HELPER_UNHEALTHY':
      return 'helper-restarting';
    default:
      return 'runtime-missing-or-incompatible';
  }
};

export const isNdiRunnable = (
  capabilities: NdiCapabilities | null | undefined,
  direction: NdiDirection = 'receive',
): boolean => {
  if (!capabilities?.feature_enabled) {
    return false;
  }
  if (capabilities.stale || capabilities.check_in_progress) {
    return false;
  }
  if (direction === 'send') {
    return capabilities.send.available === true;
  }
  if (direction === 'discovery') {
    return capabilities.discovery.available === true;
  }
  if (direction === 'direct_address') {
    return capabilities.direct_address.available === true;
  }
  return capabilities.receive.available === true;
};

export const capabilityStateLabel = (state: NdiCapabilityUiState): string => {
  switch (state) {
    case 'checking':
      return 'Checking NDI…';
    case 'available':
      return 'NDI is ready';
    case 'feature-disabled':
      return 'NDI is turned off';
    case 'plugin-missing':
      return 'NDI plugin is not installed';
    case 'runtime-missing-or-incompatible':
      return 'NDI runtime is missing or unsupported';
    case 'platform-CPU-unsupported':
      return 'This server does not support NDI';
    case 'discovery-prerequisite-unavailable':
      return 'NDI discovery is unavailable';
    case 'helper-restarting':
      return 'NDI is restarting';
    case 'stale':
      return 'Rechecking NDI…';
    default:
      return 'NDI status unknown';
  }
};
