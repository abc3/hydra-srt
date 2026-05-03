export const ACTIVE_ROUTE_STATUSES = new Set(['started', 'processing', 'starting', 'reconnecting', 'stopping']);
export const LIVE_ROUTE_STATUSES = new Set(['started', 'processing', 'starting', 'reconnecting']);

export const formatStatusLabel = (status) =>
  status ? status.charAt(0).toUpperCase() + status.slice(1) : 'Unknown';

export const getRouteRuntimeStatus = (record) => record?.schema_status || record?.status;

export const isRouteBusy = (record) =>
  ACTIVE_ROUTE_STATUSES.has((getRouteRuntimeStatus(record) || '').toLowerCase());

export const resolvePendingRouteStatus = (currentStatus, incomingStatus, pendingAction) => {
  const next = (incomingStatus || '').toLowerCase();

  if (!pendingAction || !next) {
    return incomingStatus;
  }

  if (pendingAction === 'start') {
    if (['starting', 'processing', 'started', 'reconnecting', 'failed'].includes(next)) {
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

export const getUptimeSeconds = (startedAt, status, nowMs) => {
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

export const compareUptime = (a, b, sortOrder, nowMs) => {
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
