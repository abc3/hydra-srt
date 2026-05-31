export type AppError = {
  message?: string;
  errors?: Record<string, unknown>;
};

export const getErrorMessage = (error: unknown, fallback: string): string => {
  if (typeof error === 'object' && error !== null && 'message' in error) {
    const msg = (error as AppError).message;
    if (typeof msg === 'string' && msg.length > 0) {
      return msg;
    }
  }
  if (error instanceof Error && error.message.length > 0) {
    return error.message;
  }
  return fallback;
};
