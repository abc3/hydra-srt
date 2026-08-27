type SortOrder = 'ascend' | 'descend';
type RouteRecordLike = {
  schema_status?: string | null;
  status?: string | null;
  started_at?: string | null;
};

export const ACTIVE_ROUTE_STATUSES = new Set<string>(['started', 'processing', 'starting', 'restarting', 'reconnecting', 'stopping']);
export const LIVE_ROUTE_STATUSES = new Set<string>(['started', 'processing', 'starting', 'restarting', 'reconnecting']);
export const ROUTE_RUNTIME_STATUSES = ['starting', 'restarting', 'processing', 'reconnecting', 'completed', 'failed', 'stopped'] as const;

export const formatStatusLabel = (status: string | null | undefined) =>
  status ? status.charAt(0).toUpperCase() + status.slice(1) : 'Unknown';

export const getRouteRuntimeStatus = (record: RouteRecordLike | null | undefined): string | null | undefined =>
  record?.schema_status || record?.status;

export const isRouteBusy = (record: RouteRecordLike | null | undefined) =>
  ACTIVE_ROUTE_STATUSES.has((getRouteRuntimeStatus(record) || '').toLowerCase());

export const resolvePendingRouteStatus = (
  currentStatus: string | null | undefined,
  incomingStatus: string | null | undefined,
  pendingAction: 'start' | 'stop' | null | undefined,
) => {
  const next = (incomingStatus || '').toLowerCase();

  if (!pendingAction || !next) {
    return incomingStatus;
  }

  if (pendingAction === 'start') {
    if (['starting', 'restarting', 'processing', 'started', 'reconnecting', 'failed'].includes(next)) {
      return incomingStatus;
    }

    return currentStatus || 'starting';
  }

  if (pendingAction === 'stop') {
    if (['stopping', 'stopped', 'failed'].includes(next)) {
      return incomingStatus;
    }

    return currentStatus || 'stopping';
  }

  return incomingStatus;
};

export const getUptimeSeconds = (startedAt: string | null | undefined, status: string | null | undefined, nowMs: number) => {
  if (
    typeof status !== 'string' ||
    !ACTIVE_ROUTE_STATUSES.has(status.toLowerCase()) ||
    !startedAt
  ) {
    return null;
  }

  const startedAtMs = new Date(startedAt).getTime();

  if (Number.isNaN(startedAtMs) || startedAtMs > nowMs) {
    return null;
  }

  return Math.floor((nowMs - startedAtMs) / 1000);
};

export const compareUptime = (a: RouteRecordLike, b: RouteRecordLike, sortOrder: SortOrder, nowMs: number) => {
  const uptimeA = getUptimeSeconds(a.started_at, getRouteRuntimeStatus(a), nowMs);
  const uptimeB = getUptimeSeconds(b.started_at, getRouteRuntimeStatus(b), nowMs);
  const aMissing = uptimeA == null;
  const bMissing = uptimeB == null;

  if (aMissing && bMissing) {
    return 0;
  }

  if (aMissing || bMissing) {
    if (sortOrder === 'descend') {
      return aMissing ? -1 : 1;
    }

    return aMissing ? 1 : -1;
  }

  return uptimeA - uptimeB;
};
