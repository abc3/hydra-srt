export function requestJson<T = unknown>(
  url: string,
  options?: RequestInit,
  fallbackMessage?: string,
): Promise<T>;

export function requestOptionalJson<T = unknown>(
  url: string,
  options?: RequestInit,
  fallbackMessage?: string,
): Promise<T>;

export const tagsApi: {
  list: () => Promise<{ data: unknown[] }>;
  create: (tagData: { name: string }) => Promise<{ data: unknown }>;
  update: (id: string, tagData: { name: string }) => Promise<{ data: unknown }>;
  delete: (id: string) => Promise<unknown>;
  getAll: () => Promise<{ data: string[] }>;
};
