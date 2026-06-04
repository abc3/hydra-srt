import type { ReactNode } from 'react';
import type { BadgeProps } from 'antd';

/** Shared route/domain shapes for the routes UI (API payloads are partially typed). */

export type RouteEndpoint = Record<string, unknown> & {
  id?: string;
  name?: string;
  enabled?: boolean;
  schema?: string;
  mode?: string;
  position?: number;
  host?: string;
  port?: number;
  address?: string;
  localaddress?: string;
  thumbnail_enabled?: boolean;
  thumbnail_interval_ms?: number;
  thumbnail_capture_policy?: 'running' | 'always';
  thumbnail_url?: string;
  thumbnail_version?: number;
};

export type RouteRecord = Record<string, unknown> & {
  id: string;
  name?: string;
  status?: string;
  schema_status?: string;
  started_at?: string;
  active_source_id?: string;
  last_switch_reason?: string;
  sources?: RouteEndpoint[];
  destinations?: RouteEndpoint[];
  source?: RouteEndpoint;
  tags?: string[];
  node?: string;
  enabled?: boolean;
};

export type RouteTag = {
  id?: string;
  name: string;
};

export type PaginationMeta = {
  page?: number;
  page_size?: number;
  total?: number;
};

export type ListResponse<T> = {
  data?: T[];
  meta?: PaginationMeta;
};

export type RouteFormValues = Record<string, unknown> & {
  enabled?: boolean;
  name?: string;
  node?: string;
  backup_mode?: string;
  backup_switch_after_ms?: number;
  backup_cooldown_ms?: number;
  backup_primary_stable_ms?: number;
  backup_probe_interval_ms?: number;
  sources?: RouteEndpoint[];
  destinations?: RouteEndpoint[];
  tags?: string[];
};

export type SourceTestResult = Record<string, unknown>;

export type SwitchEvent = {
  ts?: string;
};

export type TimelineSegment = {
  source_id?: string;
  from?: string;
  to?: string;
};

export type RouteActiveSourceView = {
  sources?: Array<Pick<RouteEndpoint, 'id' | 'name' | 'position'>>;
  active_source_id?: string | number;
  last_switch_reason?: string;
  last_switch_at?: string;
};

export type RouteSourceEditProps = {
  initialValues?: Partial<RouteFormValues>;
  onChange?: ((values: RouteFormValues) => void) | null;
};

export type RouteAction = 'start' | 'stop';
export type RoutePendingAction = 'start' | 'stop' | 'restart' | null;

export type AnalyticsPoint = Record<string, unknown> & {
  timestamp?: string;
  source?: number | null;
  destinations?: Record<string, number | null>;
};

export type AnalyticsMeta = Record<string, unknown> | null;

export type AnalyticsData = {
  points: AnalyticsPoint[];
  meta: AnalyticsMeta;
  switches?: unknown[];
  source_timeline?: unknown[];
};

export type StatusHistoryEvent = Record<string, unknown>;

export type StatusHistoryData = {
  events: StatusHistoryEvent[];
  meta: Record<string, unknown> | null;
};

export type StatusAnalyticsData = {
  points: AnalyticsPoint[];
  meta: Record<string, unknown> | null;
};

export type RouteStatsEntry = {
  in?: number;
  snapshot?: unknown;
  outByDestination?: Record<string, number>;
};

export type RouteStatsMap = Record<string, RouteStatsEntry>;

export type TagOption = { label: string; value: string };

export type PendingRouteActionsMap = Record<string, RouteAction | undefined>;

export type TimeRangeQuery = {
  from?: string;
  to?: string;
  window?: string;
  limit?: number;
  offset?: number;
};

export type StatsTreeNode = {
  title: ReactNode;
  key: string;
  children?: StatsTreeNode[];
};

export type RuntimeStatusMeta = {
  badgeStatus: NonNullable<BadgeProps['status']>;
  label: string;
};

export type LiveSnapshotBuffer = {
  timestamp: string;
  source: number | null;
  destinations: Record<string, number | null>;
} | null;
