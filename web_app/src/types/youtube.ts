/** Public YouTube source fields and resolver responses used by the admin UI. */

export type YoutubeVariant = {
  format_id: string;
  label: string;
  height?: number | null;
  width?: number | null;
  fps?: number | null;
  has_video?: boolean;
  has_audio?: boolean;
};

export type YoutubeInspectData = {
  live: boolean;
  variants: YoutubeVariant[];
  media_info?: YoutubeMediaInfo | null;
};

export type YoutubeMediaInfo = Record<string, unknown> & {
  title?: string | null;
  uploader?: string | null;
  format_id?: string | null;
  bitrate?: number | null;
  tbr?: number | null;
  live?: boolean | null;
  video?: Record<string, unknown> | null;
  audio?: Record<string, unknown> | null;
};

export type YoutubeEndpointFields = {
  youtube_url?: string | null;
  youtube_format_id?: string | null;
  youtube_quality_policy?: string | null;
  youtube_live_mode?: boolean | null;
  youtube_media_info?: YoutubeMediaInfo | null;
  youtube_info_updated_at?: string | null;
  youtube_end_action?: 'stop' | 'hold' | 'loop' | string | null;
};

export type YoutubeInspectResult = { data: YoutubeInspectData };
