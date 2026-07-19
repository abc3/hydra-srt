import { useCallback, useEffect, useState } from 'react';
import type { NdiCapabilities } from '../../types/ndi';
import { getErrorMessage } from '../../types/errors';
import { ndiApi } from '../../utils/ndiApi';

type Result = {
  capabilities: NdiCapabilities | null;
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
};

let cachedCapabilities: NdiCapabilities | null = null;
let cachedAtMs = 0;
const CACHE_TTL_MS = 10_000;
let inFlight: Promise<NdiCapabilities | null> | null = null;

const loadCapabilities = async (force = false): Promise<NdiCapabilities | null> => {
  const now = Date.now();
  if (!force && cachedCapabilities && now - cachedAtMs < CACHE_TTL_MS) {
    return cachedCapabilities;
  }

  if (!force && inFlight) {
    return inFlight;
  }

  inFlight = ndiApi
    .getCapabilities()
    .then((response) => {
      cachedCapabilities = response.data ?? null;
      cachedAtMs = Date.now();
      return cachedCapabilities;
    })
    .finally(() => {
      inFlight = null;
    });

  return inFlight;
};

export const useNdiCapabilities = (enabled = true): Result => {
  const [capabilities, setCapabilities] = useState<NdiCapabilities | null>(cachedCapabilities);
  const [loading, setLoading] = useState(enabled && !cachedCapabilities);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!enabled) {
      setCapabilities(null);
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);
    try {
      const next = await loadCapabilities(true);
      setCapabilities(next);
    } catch (err) {
      setError(getErrorMessage(err, 'Failed to load NDI capabilities'));
      setCapabilities(null);
    } finally {
      setLoading(false);
    }
  }, [enabled]);

  useEffect(() => {
    if (!enabled) {
      setLoading(false);
      return;
    }

    let mounted = true;
    setLoading(true);
    loadCapabilities(false)
      .then((next) => {
        if (mounted) {
          setCapabilities(next);
          setError(null);
        }
      })
      .catch((err) => {
        if (mounted) {
          setError(getErrorMessage(err, 'Failed to load NDI capabilities'));
          setCapabilities(null);
        }
      })
      .finally(() => {
        if (mounted) {
          setLoading(false);
        }
      });

    return () => {
      mounted = false;
    };
  }, [enabled]);

  return { capabilities, loading, error, refresh };
};

export default useNdiCapabilities;
