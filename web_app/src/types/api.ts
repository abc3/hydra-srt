export type ApiDataResponse<T> = {
  data: T;
};

export type McpToken = {
  id: string;
  name: string;
  inserted_at?: string;
  updated_at?: string;
};

export type McpTokenCreated = McpToken & {
  token: string;
};

export type McpTokenInput = {
  name: string;
};
