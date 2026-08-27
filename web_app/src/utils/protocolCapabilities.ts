export type ProtocolSchema = 'SRT' | 'UDP' | 'RTP' | 'RTMP' | 'NDI' | 'YOUTUBE';

export type ProtocolDirection = 'source' | 'destination';

export type ProtocolCapability = {
  schema: ProtocolSchema;
  label: string;
  source: boolean;
  destination: boolean;
  /** When true, protocol appears only if product feature_enabled is true. */
  requiresFeatureFlag: boolean;
};

/** Typed protocol registry used by route/source/destination forms. */
export const PROTOCOL_CAPABILITIES: readonly ProtocolCapability[] = [
  { schema: 'SRT', label: 'SRT', source: true, destination: true, requiresFeatureFlag: false },
  { schema: 'UDP', label: 'UDP', source: true, destination: true, requiresFeatureFlag: false },
  { schema: 'RTP', label: 'RTP', source: true, destination: false, requiresFeatureFlag: false },
  { schema: 'RTMP', label: 'RTMP', source: true, destination: true, requiresFeatureFlag: false },
  { schema: 'NDI', label: 'NDI', source: true, destination: true, requiresFeatureFlag: true },
  { schema: 'YOUTUBE', label: 'YouTube', source: true, destination: false, requiresFeatureFlag: false },
] as const;

export const listSelectableProtocols = (
  direction: ProtocolDirection,
  options: { ndiFeatureEnabled?: boolean } = {},
): ProtocolCapability[] =>
  PROTOCOL_CAPABILITIES.filter((protocol) => {
    if (direction === 'source' && !protocol.source) {
      return false;
    }
    if (direction === 'destination' && !protocol.destination) {
      return false;
    }
    if (protocol.requiresFeatureFlag && options.ndiFeatureEnabled !== true) {
      return false;
    }
    return true;
  });
