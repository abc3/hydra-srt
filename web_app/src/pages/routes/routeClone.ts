import type { RouteEndpoint, RouteRecord } from '../../types/routes';

export const CLONE_NAME_PREFIX = 'CLONE - ';

export type CloneWarningKind = 'bind_target' | 'ndi_sender_name';

export type CloneWarning = {
  list: 'sources' | 'destinations';
  index: number;
  name: string;
  kind: CloneWarningKind;
};

export type RouteCloneDraft = Record<string, unknown> & {
  name: string;
  enabled: boolean;
  sources: RouteEndpoint[];
  destinations: RouteEndpoint[];
};

const ROUTE_KEYS_TO_DELETE = [
  'id',
  'status',
  'schema_status',
  'started_at',
  'stopped_at',
  'active_source_id',
  'last_switch_reason',
  'last_switch_at',
  'lock_version',
  'inserted_at',
  'updated_at',
];

const ENDPOINT_KEYS_TO_DELETE = [
  'id',
  'route_id',
  'position',
  'status',
  'schema_status',
  'started_at',
  'stopped_at',
  'lock_version',
  'inserted_at',
  'updated_at',
  'last_probe_at',
  'last_failure_at',
  'ndi_sender_name_key',
];

const normalize = (value: unknown): string =>
  typeof value === 'string' ? value.trim().toLowerCase() : '';

const validPort = (value: unknown): boolean => {
  if (typeof value === 'number') {
    return Number.isInteger(value) && value >= 1 && value <= 65_535;
  }

  if (typeof value !== 'string' || value.trim() === '') {
    return false;
  }

  const port = Number(value);
  return Number.isInteger(port) && port >= 1 && port <= 65_535;
};

const bindPort = (endpoint: RouteEndpoint): unknown =>
  endpoint.localport === null || endpoint.localport === undefined
    ? endpoint.port
    : endpoint.localport;

const reservesBindTarget = (endpoint: RouteEndpoint, list: CloneWarning['list']): boolean => {
  const schema = normalize(endpoint.schema);

  if (schema === 'srt') {
    return ['listener', 'rendezvous'].includes(normalize(endpoint.mode)) && validPort(bindPort(endpoint));
  }

  if (schema === 'udp' || schema === 'rtp') {
    if (list === 'sources') {
      return validPort(bindPort(endpoint));
    }

    return schema === 'udp' && validPort(endpoint.localport);
  }

  return false;
};

const warningName = (endpoint: RouteEndpoint, index: number, list: CloneWarning['list']): string => {
  if (typeof endpoint.name === 'string' && endpoint.name.trim() !== '') {
    return endpoint.name;
  }

  const label = list === 'sources' ? 'Source' : 'Destination';
  return `${label} ${index + 1}`;
};

const cloneEndpoints = (
  endpoints: RouteEndpoint[],
  list: CloneWarning['list'],
): { endpoints: RouteEndpoint[]; warnings: CloneWarning[] } => {
  const orderedEndpoints = list === 'sources'
    ? [...endpoints].sort((left, right) => Number(left.position) - Number(right.position))
    : [...endpoints];
  const warnings: CloneWarning[] = [];

  const clonedEndpoints = orderedEndpoints.map((endpoint, index) => {
    const clone = { ...endpoint };
    ENDPOINT_KEYS_TO_DELETE.forEach((key) => delete clone[key]);

    if (reservesBindTarget(endpoint, list)) {
      warnings.push({
        list,
        index,
        name: warningName(endpoint, index, list),
        kind: 'bind_target',
      });
    }

    if (
      list === 'destinations' &&
      normalize(endpoint.schema) === 'ndi' &&
      typeof endpoint.ndi_sender_name === 'string' &&
      endpoint.ndi_sender_name.trim() !== ''
    ) {
      const clonedSenderName = buildCloneName(endpoint.ndi_sender_name);
      clone.ndi_sender_name = clonedSenderName;
      if (clonedSenderName !== endpoint.ndi_sender_name) {
        warnings.push({
          list,
          index,
          name: warningName(endpoint, index, list),
          kind: 'ndi_sender_name',
        });
      }
    }

    return clone;
  });

  return { endpoints: clonedEndpoints, warnings };
};

export const buildCloneName = (name: string | null | undefined): string => {
  const trimmed = name?.trim() ?? '';
  return trimmed.startsWith(CLONE_NAME_PREFIX) ? trimmed : `${CLONE_NAME_PREFIX}${trimmed}`;
};

export const buildRouteClone = (route: RouteRecord): { route: RouteCloneDraft; warnings: CloneWarning[] } => {
  const sources = Array.isArray(route.sources) ? route.sources : [];
  const destinations = Array.isArray(route.destinations) ? route.destinations : [];
  const clonedSources = cloneEndpoints(sources, 'sources');
  const clonedDestinations = cloneEndpoints(destinations, 'destinations');
  const clonedRoute = { ...route } as Record<string, unknown>;

  ROUTE_KEYS_TO_DELETE.forEach((key) => delete clonedRoute[key]);

  if (Array.isArray(clonedRoute.tags)) {
    clonedRoute.tags = [...clonedRoute.tags];
  }

  return {
    route: {
      ...clonedRoute,
      name: buildCloneName(route.name),
      enabled: false,
      sources: clonedSources.endpoints,
      destinations: clonedDestinations.endpoints,
    },
    warnings: [...clonedSources.warnings, ...clonedDestinations.warnings],
  };
};
