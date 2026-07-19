/** Typed NDI REST/UI contracts (capabilities, discovery, probe, health). */

export type NdiSelectionMode = 'discovery_name' | 'direct_address';

export type NdiMediaPolicy =
  | 'video_and_audio_required'
  | 'video_required_audio_optional'
  | 'video_only'
  | 'audio_only';

export type NdiBandwidth = 'highest' | 'audio_only';

export type NdiColorFormat =
  | 'uyvy-bgra'
  | 'fastest'
  | 'best'
  | 'bgrx-bgra'
  | 'rgbx-rgba'
  | 'uyvy-rgba';

export type NdiTimestampMode =
  | 'auto'
  | 'receive-time'
  | 'timecode'
  | 'timestamp'
  | 'receive-time-vs-timestamp';

export type NdiReasonCode = string;

export type NdiPluginInfo = {
  available: boolean;
  revision: string | null;
};

export type NdiRuntimeInfo = {
  available: boolean;
  major: number | null;
  version: string | null;
};

export type NdiGatedFormats = {
  available: boolean;
  reason_codes: NdiReasonCode[];
  formats: string[];
};

export type NdiGatedDiscovery = {
  available: boolean;
  reason_codes: NdiReasonCode[];
  mode: string;
};

export type NdiGatedDirect = {
  available: boolean;
  reason_codes: NdiReasonCode[];
};

export type NdiCapabilities = {
  node_id: string;
  feature_enabled: boolean;
  plugin: NdiPluginInfo;
  runtime: NdiRuntimeInfo;
  receive: NdiGatedFormats;
  send: NdiGatedFormats;
  discovery: NdiGatedDiscovery;
  direct_address: NdiGatedDirect;
  checked_at: string;
  expires_at: string;
  stale: boolean;
  check_in_progress: boolean;
};

export type NdiCapabilityUiState =
  | 'checking'
  | 'available'
  | 'feature-disabled'
  | 'plugin-missing'
  | 'runtime-missing-or-incompatible'
  | 'platform-CPU-unsupported'
  | 'discovery-prerequisite-unavailable'
  | 'helper-restarting'
  | 'stale';

export type NdiSourceRow = {
  selection_token: string;
  name: string;
  url_address: string | null;
  display_name: string;
  last_seen_at: string | null;
  stale: boolean;
};

export type NdiSourcesMeta = {
  generation: string;
  scanned_at: string | null;
  expires_at: string;
  refresh_in_progress: boolean;
  truncated: boolean;
  result_count: number;
  duplicate_name_groups: Array<{
    name: string;
    count: number;
    reason_code?: string;
  }>;
};

export type NdiSourcesResponse = {
  data: NdiSourceRow[];
  meta: NdiSourcesMeta;
};

export type NdiProbeCaps = {
  video?: unknown;
  audio?: unknown;
};

export type NdiProbeResult = {
  ok: boolean;
  code: string | null;
  caps: NdiProbeCaps;
  frames?: { video?: number; audio?: number } | number | null;
  skew_ms?: number | null;
  elapsed_ms?: number | null;
  probe_instance_id?: string | null;
  detail?: string | null;
};

export type NdiEndpointHealthState =
  | 'validating'
  | 'discovering'
  | 'connecting'
  | 'negotiating'
  | 'streaming'
  | 'advertising'
  | 'reconnecting'
  | 'degraded'
  | 'unavailable'
  | 'configuration_error'
  | 'stopped'
  | 'disabled'
  | 'standby'
  | 'probing'
  | string;

export type NdiEndpointHealthRecord = {
  event?: string;
  route_id?: string;
  config_revision?: string;
  process_instance_id?: string;
  sequence?: number;
  endpoint_id: string;
  direction?: 'source' | 'destination' | string;
  transport?: string;
  state?: NdiEndpointHealthState;
  reason_code?: string | null;
  retryable?: boolean | null;
  retry_domain?: string | null;
  observed_at_ms?: number | null;
  state_changed_at?: string | null;
  detail?: string | null;
  last_video_buffer_age_ms?: number | null;
  last_audio_buffer_age_ms?: number | null;
  attempt?: number | null;
  video_caps?: unknown;
  audio_caps?: unknown;
  drops?: number | null;
  queue_level?: number | null;
  reconnect_attempts?: number | null;
  receiver_count?: number | null;
  current_name?: string | null;
  current_address?: string | null;
  skew_ms?: number | null;
};

export type NdiEndpointHealthSnapshot = {
  generated_at: string;
  config_revision: string | null;
  process_instance_id: string | null;
  last_sequence: number;
  endpoints: NdiEndpointHealthRecord[];
};

export type NdiEndpointFields = {
  ndi_selection_mode?: NdiSelectionMode | null;
  ndi_source_name?: string | null;
  ndi_source_address?: string | null;
  ndi_observed_address_snapshot?: string | null;
  ndi_observed_name_snapshot?: string | null;
  ndi_selection_observed_at?: string | null;
  ndi_receiver_name?: string | null;
  ndi_media_policy?: NdiMediaPolicy | null;
  ndi_bandwidth?: NdiBandwidth | null;
  ndi_color_format?: NdiColorFormat | null;
  ndi_timestamp_mode?: NdiTimestampMode | null;
  ndi_connect_timeout_ms?: number | null;
  ndi_receive_timeout_ms?: number | null;
  ndi_track_discovery_timeout_ms?: number | null;
  ndi_max_queue_length?: number | null;
  ndi_sender_name?: string | null;
  /** Transient discovery selection; never persisted as endpoint state. */
  selection_token?: string | null;
};
