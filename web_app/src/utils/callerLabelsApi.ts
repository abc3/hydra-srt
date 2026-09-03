import { requestJson, requestOptionalJson } from './api';
import type { ApiDataResponse } from '../types/api';
import type { CallerLabel, CallerLabelInput } from '../types/routes';

export const callerLabelsApi = {
  list: async (): Promise<ApiDataResponse<CallerLabel[]>> => {
    return requestJson('/api/caller-labels', {}, 'Failed to load caller labels');
  },

  create: async (labelData: CallerLabelInput): Promise<ApiDataResponse<CallerLabel>> => {
    return requestJson('/api/caller-labels', {
      method: 'POST',
      body: JSON.stringify({ caller_label: labelData }),
    }, 'Failed to create caller label');
  },

  update: async (id: string, labelData: CallerLabelInput): Promise<ApiDataResponse<CallerLabel>> => {
    return requestJson(`/api/caller-labels/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ caller_label: labelData }),
    }, 'Failed to update caller label');
  },

  delete: async (id: string): Promise<{ success: true }> => {
    return requestOptionalJson(`/api/caller-labels/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete caller label');
  },
};
