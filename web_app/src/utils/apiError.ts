export type ApiError = Error & {
  status?: number;
  payload?: unknown;
  errors?: unknown;
};

export const parseJsonResponse = async (response: Response): Promise<unknown> => {
  const contentType = response.headers.get('content-type');

  if (!contentType || !contentType.includes('application/json')) {
    return null;
  }

  return response.json();
};

export const throwApiErrorIfNeeded = async (response: Response, fallbackMessage: string) => {
  if (response.ok) {
    return;
  }

  const payload = (await parseJsonResponse(response)) as Record<string, unknown> | null;
  const nestedErrorMessage =
    typeof payload?.error === 'object' &&
    payload.error !== null &&
    'message' in payload.error &&
    typeof payload.error.message === 'string'
      ? payload.error.message
      : null;
  const message =
    nestedErrorMessage ||
    payload?.error ||
    payload?.message ||
    (payload?.errors ? 'Validation failed' : null) ||
    fallbackMessage;
  const error = new Error(typeof message === 'string' ? message : fallbackMessage) as ApiError;
  error.status = response.status;
  error.payload = payload;
  error.errors = payload?.errors;
  throw error;
};
