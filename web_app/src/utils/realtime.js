import { Socket } from 'phoenix';
import { API_BASE_URL } from './constants';
import { getToken } from './auth';

let socket = null;
let channel = null;
let currentToken = null;
let channelJoined = false;
let channelJoinInFlight = false;
let statsSubscribed = false;
let statsSubscribePending = false;
let statsSubscribedOnServer = false;
let systemPipelinesSubscribed = false;
let systemPipelinesSubscribePending = false;
let systemPipelinesSubscribedOnServer = false;
let nodesSubscribed = false;
let nodesSubscribePending = false;
let nodesSubscribedOnServer = false;
const statsListeners = new Set();
const systemPipelinesListeners = new Set();
const nodesListeners = new Set();
const itemSubscriptions = new Map();
const itemSubscriptionsOnServer = new Set();
const itemSourceListeners = new Map();
const routeEventsListeners = new Map();
const routeEventsSubscriptionsOnServer = new Set();

/**
 * Same rules as the pre-refactor UI (e.g. RouteItem): pass the HTTP `/socket`
 * endpoint into Phoenix; it appends `/websocket` itself.
 *
 * When API_BASE_URL shares the page origin (typical Vite dev: UI on :5173 and
 * constants fall back to pageOrigin), use a relative `/socket` so the dev
 * server can proxy WebSocket upgrades to Phoenix (see vite.config.js).
 */
const getSocketEndpoint = () => {
  try {
    const api = new URL(API_BASE_URL, window.location.origin);
    const page = new URL(window.location.href);

    if (api.origin === page.origin) {
      return '/socket';
    }

    api.protocol = api.protocol === 'https:' ? 'wss:' : 'ws:';
    api.pathname = '/socket';
    api.search = '';
    api.hash = '';
    return api.toString();
  } catch {
    return '/socket';
  }
};

const pushStatsSubscription = () => {
  if (!channel || !statsSubscribed) {
    return;
  }

  if (!channelJoined || channelJoinInFlight) {
    statsSubscribePending = true;
    return;
  }

  statsSubscribePending = false;
  channel
    .push('stats:subscribe', {})
    .receive('ok', () => {
      statsSubscribedOnServer = true;
    })
    .receive('error', (error) => {
      console.error('[realtime] stats subscribe failed', error);
    });
};

const pushStatsUnsubscription = () => {
  statsSubscribePending = false;

  if (!channel || !channelJoined || !statsSubscribedOnServer) {
    return;
  }

  channel
    .push('stats:unsubscribe', {})
    .receive('ok', () => {
      statsSubscribedOnServer = false;
    })
    .receive('error', (error) => {
      console.error('[realtime] stats unsubscribe failed', error);
    });
};

const pushSystemPipelinesSubscription = () => {
  if (!channel || !systemPipelinesSubscribed) {
    return;
  }

  if (!channelJoined || channelJoinInFlight) {
    systemPipelinesSubscribePending = true;
    return;
  }

  systemPipelinesSubscribePending = false;
  channel
    .push('system_pipelines:subscribe', {})
    .receive('ok', () => {
      systemPipelinesSubscribedOnServer = true;
    })
    .receive('error', (error) => {
      console.error('[realtime] system pipelines subscribe failed', error);
    });
};

const pushSystemPipelinesUnsubscription = () => {
  systemPipelinesSubscribePending = false;

  if (!channel || !channelJoined || !systemPipelinesSubscribedOnServer) {
    return;
  }

  channel
    .push('system_pipelines:unsubscribe', {})
    .receive('ok', () => {
      systemPipelinesSubscribedOnServer = false;
    })
    .receive('error', (error) => {
      console.error('[realtime] system pipelines unsubscribe failed', error);
    });
};

const pushNodesSubscription = () => {
  if (!channel || !nodesSubscribed) {
    return;
  }

  if (!channelJoined || channelJoinInFlight) {
    nodesSubscribePending = true;
    return;
  }

  nodesSubscribePending = false;
  channel
    .push('nodes:subscribe', {})
    .receive('ok', () => {
      nodesSubscribedOnServer = true;
    })
    .receive('error', (error) => {
      console.error('[realtime] nodes subscribe failed', error);
    });
};

const pushNodesUnsubscription = () => {
  nodesSubscribePending = false;

  if (!channel || !channelJoined || !nodesSubscribedOnServer) {
    return;
  }

  channel
    .push('nodes:unsubscribe', {})
    .receive('ok', () => {
      nodesSubscribedOnServer = false;
    })
    .receive('error', (error) => {
      console.error('[realtime] nodes unsubscribe failed', error);
    });
};

const addItemListener = (itemId, listener) => {
  const current = itemSubscriptions.get(itemId) || { listeners: new Set(), refCount: 0 };

  if (typeof listener === 'function') {
    current.listeners.add(listener);
  }

  current.refCount += 1;
  itemSubscriptions.set(itemId, current);
};

const removeItemListener = (itemId, listener) => {
  const current = itemSubscriptions.get(itemId);

  if (!current) {
    return 0;
  }

  if (typeof listener === 'function') {
    current.listeners.delete(listener);
  }

  current.refCount = Math.max(0, current.refCount - 1);

  if (current.refCount === 0) {
    itemSubscriptions.delete(itemId);
    return 0;
  }

  itemSubscriptions.set(itemId, current);
  return current.refCount;
};

const pushItemSubscription = (itemId) => {
  if (!channel || !itemId || !itemSubscriptions.has(itemId)) {
    return;
  }

  if (!channelJoined || channelJoinInFlight) {
    return;
  }

  if (itemSubscriptionsOnServer.has(itemId)) {
    return;
  }

  channel
    .push('item:subscribe', { item_id: itemId })
    .receive('ok', () => {
      itemSubscriptionsOnServer.add(itemId);
    })
    .receive('error', (error) => {
      console.error('[realtime] item subscribe failed', itemId, error);
    });
};

const pushItemUnsubscription = (itemId) => {
  if (!channel || !channelJoined || !itemSubscriptionsOnServer.has(itemId)) {
    return;
  }

  channel
    .push('item:unsubscribe', { item_id: itemId })
    .receive('ok', () => {
      itemSubscriptionsOnServer.delete(itemId);
    })
    .receive('error', (error) => {
      console.error('[realtime] item unsubscribe failed', itemId, error);
    });
};

const pushAllItemSubscriptions = () => {
  Array.from(itemSubscriptions.keys()).forEach((itemId) => {
    pushItemSubscription(itemId);
  });
};

const pushRouteEventsSubscription = (routeId) => {
  if (!channel || !routeId || !routeEventsListeners.has(routeId)) {
    return;
  }

  if (!channelJoined || channelJoinInFlight) {
    return;
  }

  if (routeEventsSubscriptionsOnServer.has(routeId)) {
    return;
  }

  channel
    .push('events:subscribe', { route_id: routeId })
    .receive('ok', () => {
      routeEventsSubscriptionsOnServer.add(routeId);
    })
    .receive('error', (error) => {
      console.error('[realtime] events subscribe failed', routeId, error);
    });
};

const pushRouteEventsUnsubscription = (routeId) => {
  if (!channel || !channelJoined || !routeEventsSubscriptionsOnServer.has(routeId)) {
    return;
  }

  channel
    .push('events:unsubscribe', { route_id: routeId })
    .receive('ok', () => {
      routeEventsSubscriptionsOnServer.delete(routeId);
    })
    .receive('error', (error) => {
      console.error('[realtime] events unsubscribe failed', routeId, error);
    });
};

const pushAllRouteEventsSubscriptions = () => {
  Array.from(routeEventsListeners.keys()).forEach((routeId) => {
    pushRouteEventsSubscription(routeId);
  });
};

const closeRealtimeTransport = () => {
  if (channel) {
    channel.leave();
  }

  if (socket) {
    socket.disconnect();
  }

  socket = null;
  channel = null;
  currentToken = null;
  channelJoined = false;
  channelJoinInFlight = false;
  statsSubscribedOnServer = false;
  systemPipelinesSubscribedOnServer = false;
  nodesSubscribedOnServer = false;
  itemSubscriptionsOnServer.clear();
  routeEventsSubscriptionsOnServer.clear();
};

export const connectRealtime = () => {
  const token = getToken();

  if (!token) {
    disconnectRealtime();
    return null;
  }

  if (socket && currentToken === token) {
    return channel;
  }

  closeRealtimeTransport();
  currentToken = token;
  socket = new Socket(getSocketEndpoint(), { params: { token } });
  channel = socket.channel('realtime');
  channelJoined = false;
  channelJoinInFlight = true;
  statsSubscribedOnServer = false;

  channel.on('stats', (payload) => {
    statsListeners.forEach((listener) => listener(payload));
  });

  channel.on('system_pipelines', (payload) => {
    systemPipelinesListeners.forEach((listener) => listener(payload));
  });

  channel.on('nodes', (payload) => {
    nodesListeners.forEach((listener) => listener(payload));
  });

  channel.on('item_status', (payload) => {
    const itemId = payload?.item_id;

    if (!itemId) {
      return;
    }

    const listeners = itemSubscriptions.get(itemId)?.listeners;

    if (!listeners || listeners.size === 0) {
      return;
    }

    listeners.forEach((listener) => listener(payload));
  });

  channel.on('item_source', (payload) => {
    const itemId = payload?.item_id;

    if (!itemId) {
      return;
    }

    const listeners = itemSourceListeners.get(itemId);

    if (!listeners || listeners.size === 0) {
      return;
    }

    listeners.forEach((listener) => listener(payload));
  });

  channel.on('event', (payload) => {
    const routeId = payload?.route_id;

    if (!routeId) {
      return;
    }

    const listeners = routeEventsListeners.get(routeId);

    if (!listeners || listeners.size === 0) {
      return;
    }

    listeners.forEach((listener) => listener(payload));
  });

  channel.onError((error) => {
    console.error('[realtime] channel error', error);
  });

  channel.onClose(() => {
    channelJoined = false;
    channelJoinInFlight = false;
    statsSubscribedOnServer = false;
    systemPipelinesSubscribedOnServer = false;
    nodesSubscribedOnServer = false;
    itemSubscriptionsOnServer.clear();
    routeEventsSubscriptionsOnServer.clear();
  });

  socket.onOpen(() => {
    console.debug('[realtime] socket connected');
  });

  socket.onError((error) => {
    console.error('[realtime] socket transport error', error);
  });

  socket.onClose(() => {
    channelJoined = false;
    channelJoinInFlight = false;
    statsSubscribedOnServer = false;
    systemPipelinesSubscribedOnServer = false;
    nodesSubscribedOnServer = false;
    itemSubscriptionsOnServer.clear();
    routeEventsSubscriptionsOnServer.clear();
  });

  socket.connect();

  channel
    .join()
    .receive('ok', () => {
      channelJoined = true;
      channelJoinInFlight = false;

      if (statsSubscribePending || statsSubscribed) {
        pushStatsSubscription();
      }

      if (systemPipelinesSubscribePending || systemPipelinesSubscribed) {
        pushSystemPipelinesSubscription();
      }

      if (nodesSubscribePending || nodesSubscribed) {
        pushNodesSubscription();
      }

      pushAllItemSubscriptions();
      pushAllRouteEventsSubscriptions();
    })
    .receive('error', (error) => {
      channelJoinInFlight = false;
      console.error('[realtime] channel join failed', error);
    });

  return channel;
};

export const disconnectRealtime = () => {
  closeRealtimeTransport();
  statsSubscribed = false;
  statsSubscribePending = false;
  statsSubscribedOnServer = false;
  systemPipelinesSubscribed = false;
  systemPipelinesSubscribePending = false;
  systemPipelinesSubscribedOnServer = false;
  nodesSubscribed = false;
  nodesSubscribePending = false;
  nodesSubscribedOnServer = false;
  statsListeners.clear();
  systemPipelinesListeners.clear();
  nodesListeners.clear();
  itemSubscriptions.clear();
  itemSubscriptionsOnServer.clear();
  itemSourceListeners.clear();
  routeEventsListeners.clear();
  routeEventsSubscriptionsOnServer.clear();
};

export const subscribeToStats = (listener) => {
  if (typeof listener === 'function') {
    statsListeners.add(listener);
  }

  statsSubscribed = true;
  connectRealtime();
  pushStatsSubscription();

  return () => {
    if (typeof listener === 'function') {
      statsListeners.delete(listener);
    }

    if (statsListeners.size === 0) {
      statsSubscribed = false;
      pushStatsUnsubscription();
    }
  };
};

export const subscribeToNodes = (listener) => {
  if (typeof listener === 'function') {
    nodesListeners.add(listener);
  }

  nodesSubscribed = true;
  connectRealtime();
  pushNodesSubscription();

  return () => {
    if (typeof listener === 'function') {
      nodesListeners.delete(listener);
    }

    if (nodesListeners.size === 0) {
      nodesSubscribed = false;
      pushNodesUnsubscription();
    }
  };
};

export const subscribeToSystemPipelines = (listener) => {
  if (typeof listener === 'function') {
    systemPipelinesListeners.add(listener);
  }

  systemPipelinesSubscribed = true;
  connectRealtime();
  pushSystemPipelinesSubscription();

  return () => {
    if (typeof listener === 'function') {
      systemPipelinesListeners.delete(listener);
    }

    if (systemPipelinesListeners.size === 0) {
      systemPipelinesSubscribed = false;
      pushSystemPipelinesUnsubscription();
    }
  };
};

export const subscribeToItemStatus = (itemId, listener) => {
  if (typeof itemId !== 'string' || itemId.length === 0) {
    return () => {};
  }

  addItemListener(itemId, listener);
  connectRealtime();
  pushItemSubscription(itemId);

  return () => {
    const remaining = removeItemListener(itemId, listener);

    if (remaining === 0) {
      pushItemUnsubscription(itemId);
    }
  };
};

export const subscribeToItemSource = (itemId, listener) => {
  if (typeof itemId !== 'string' || itemId.length === 0) {
    return () => {};
  }

  const listeners = itemSourceListeners.get(itemId) || new Set();

  if (typeof listener === 'function') {
    listeners.add(listener);
  }

  itemSourceListeners.set(itemId, listeners);

  connectRealtime();
  addItemListener(itemId);
  pushItemSubscription(itemId);

  return () => {
    const currentListeners = itemSourceListeners.get(itemId);

    if (currentListeners && typeof listener === 'function') {
      currentListeners.delete(listener);
    }

    if (!currentListeners || currentListeners.size === 0) {
      itemSourceListeners.delete(itemId);
      const remaining = removeItemListener(itemId);

      if (remaining === 0) {
        pushItemUnsubscription(itemId);
      }
    } else {
      itemSourceListeners.set(itemId, currentListeners);
    }
  };
};

export const subscribeToRouteEvents = (routeId, listener) => {
  if (typeof routeId !== 'string' || routeId.length === 0) {
    return () => {};
  }

  const listeners = routeEventsListeners.get(routeId) || new Set();

  if (typeof listener === 'function') {
    listeners.add(listener);
  }

  routeEventsListeners.set(routeId, listeners);
  connectRealtime();
  pushRouteEventsSubscription(routeId);

  return () => {
    const currentListeners = routeEventsListeners.get(routeId);

    if (currentListeners && typeof listener === 'function') {
      currentListeners.delete(listener);
    }

    if (!currentListeners || currentListeners.size === 0) {
      routeEventsListeners.delete(routeId);
      pushRouteEventsUnsubscription(routeId);
    } else {
      routeEventsListeners.set(routeId, currentListeners);
    }
  };
};
