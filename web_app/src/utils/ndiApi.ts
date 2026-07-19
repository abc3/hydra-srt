import { requestJson } from './api';
import type { ApiDataResponse } from '../types/api';
import type {
  NdiCapabilities,
  NdiEndpointHealthSnapshot,
  NdiProbeResult,
  NdiSourcesResponse,
} from '../types/ndi';

type ProbeBody =
  | { endpoint_id: string }
  | { source_id: string }
  | { endpoint: Record<string, unknown> }
  | { source: Record<string, unknown> };

export const ndiApi = {
  getCapabilities: async (): Promise<ApiDataResponse<NdiCapabilities>> =>
    requestJson('/api/system/ndi/capabilities', {}, 'Failed to load NDI capabilities'),

  listSources: async (params: { refresh?: boolean; q?: string } = {}): Promise<NdiSourcesResponse> => {
    const query = new URLSearchParams();
    if (params.refresh) {
      query.set('refresh', 'true');
    }
    if (params.q) {
      query.set('q', params.q);
    }
    const suffix = query.toString() ? `?${query.toString()}` : '';
    return requestJson(`/api/ndi/sources${suffix}`, {}, 'Failed to load NDI sources');
  },

  refreshDiscovery: async (): Promise<ApiDataResponse<{ generation: string }>> =>
    requestJson(
      '/api/ndi/discovery/refresh',
      { method: 'POST' },
      'Failed to refresh NDI discovery',
    ),

  probe: async (body: ProbeBody): Promise<ApiDataResponse<NdiProbeResult>> =>
    requestJson(
      '/api/ndi/probes',
      {
        method: 'POST',
        body: JSON.stringify(body),
      },
      'Failed to probe NDI input',
    ),

  getEndpointHealth: async (routeId: string): Promise<ApiDataResponse<NdiEndpointHealthSnapshot>> =>
    requestJson(
      `/api/routes/${encodeURIComponent(routeId)}/endpoint-health`,
      {},
      'Failed to load NDI endpoint health',
    ),
};
