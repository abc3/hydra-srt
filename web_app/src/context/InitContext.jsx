import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { initApi } from '../utils/api';

const INIT_FALLBACK = {
  version: 'unknown',
  system_version: 'unknown',
  elixir_version: 'unknown',
  erlang_version: 'unknown',
  rust_version: 'unknown',
  demo_data: false,
};
const InitContext = createContext(INIT_FALLBACK);

let initPromise;

const loadInitOnce = () => {
  if (!initPromise) {
    initPromise = initApi.get().catch((error) => {
      console.error('Failed to load init payload:', error);
      return INIT_FALLBACK;
    });
  }

  return initPromise;
};

export const InitProvider = ({ children }) => {
  const [initData, setInitData] = useState(INIT_FALLBACK);

  useEffect(() => {
    let active = true;

    loadInitOnce().then((payload) => {
      if (active) {
        setInitData(payload);
      }
    });

    return () => {
      active = false;
    };
  }, []);

  const value = useMemo(() => initData, [initData]);

  return <InitContext.Provider value={value}>{children}</InitContext.Provider>;
};

export const useInit = () => useContext(InitContext);
