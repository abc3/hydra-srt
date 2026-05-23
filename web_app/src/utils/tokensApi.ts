import { requestJson, requestOptionalJson } from './api';
import type { ApiDataResponse, McpToken, McpTokenCreated, McpTokenInput } from '../types/api';

export const tokensApi = {
  list: async (): Promise<ApiDataResponse<McpToken[]>> => {
    return requestJson('/api/tokens', {}, 'Failed to load tokens');
  },

  create: async (tokenData: McpTokenInput): Promise<ApiDataResponse<McpTokenCreated>> => {
    return requestJson('/api/tokens', {
      method: 'POST',
      body: JSON.stringify({ token: tokenData }),
    }, 'Failed to create token');
  },

  update: async (id: string, tokenData: McpTokenInput): Promise<ApiDataResponse<McpToken>> => {
    return requestJson(`/api/tokens/${id}`, {
      method: 'PUT',
      body: JSON.stringify({ token: tokenData }),
    }, 'Failed to update token');
  },

  delete: async (id: string): Promise<{ success: true }> => {
    return requestOptionalJson(`/api/tokens/${id}`, {
      method: 'DELETE',
    }, 'Failed to delete token');
  },
};
