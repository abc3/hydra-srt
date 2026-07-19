import type { NdiBandwidth, NdiColorFormat, NdiMediaPolicy, NdiSelectionMode, NdiTimestampMode } from '../../types/ndi';

/** Mirrors `HydraSrt.Api.Endpoint` / hydra-plan allowlists exactly. */

export const NDI_SELECTION_MODES: NdiSelectionMode[] = ['discovery_name', 'direct_address'];

export const NDI_MEDIA_POLICIES: NdiMediaPolicy[] = [
  'video_and_audio_required',
  'video_required_audio_optional',
  'video_only',
  'audio_only',
];

export const NDI_BANDWIDTHS: NdiBandwidth[] = ['highest', 'audio_only'];

export const NDI_COLOR_FORMATS: NdiColorFormat[] = [
  'uyvy-bgra',
  'fastest',
  'best',
  'bgrx-bgra',
  'rgbx-rgba',
  'uyvy-rgba',
];

export const NDI_TIMESTAMP_MODES: NdiTimestampMode[] = [
  'auto',
  'receive-time',
  'timecode',
  'timestamp',
  'receive-time-vs-timestamp',
];

export const NDI_TIMEOUT_MS_MIN = 1000;
export const NDI_TIMEOUT_MS_MAX = 60_000;
export const NDI_MAX_QUEUE_LENGTH_MIN = 1;
export const NDI_MAX_QUEUE_LENGTH_MAX = 64;

export const NDI_DEFAULT_CONNECT_TIMEOUT_MS = 10_000;
export const NDI_DEFAULT_RECEIVE_TIMEOUT_MS = 5_000;
export const NDI_DEFAULT_TRACK_DISCOVERY_TIMEOUT_MS = 10_000;
export const NDI_DEFAULT_MAX_QUEUE_LENGTH = 4;

export const NDI_SNAPSHOT_FIELDS = [
  'ndi_observed_address_snapshot',
  'ndi_observed_name_snapshot',
  'ndi_selection_observed_at',
  'ndi_sender_name_key',
] as const;

export const NDI_TRADEMARK_NOTICE =
  'NDI® is a registered trademark of Vizrt NDI AB. HydraSRT does not include the NDI runtime.';

export const NDI_VIDEO_URL = 'https://ndi.video';

export const NDI_SENDER_NAME_GUIDANCE =
  'Use a stable Machine (Channel) style name. Prefer ASCII letters, digits, spaces, and parentheses. Keep names unique on the LAN.';

export const NDI_OUTPUT_FORMAT_STATEMENT = 'NDI High Bandwidth (SDR)';
