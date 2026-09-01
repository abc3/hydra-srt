import { Socket } from 'phoenix';
import { API_BASE_URL } from './constants';
import { getToken } from './auth';

type Payload = Record<string, unknown>;
type Listener = (payload: Payload) => void;
type ItemSubscription = { listeners: Set<Listener>; refCount: number };
type SubscriptionOperation = { action: 'subscribe' | 'unsubscribe' };

let socket: any = null;
let channel: any = null;
let currentToken: string | null = null;
let channelJoined = false;
let channelJoinInFlight = false;
let statsSubscribed = false;
let statsSubscribePending = false;
let statsSubscribedOnServer = false;
let statsSubscriptionOperation: SubscriptionOperation | null = null;
let systemPipelinesSubscribed = false;
let systemPipelinesSubscribePending = false;
let systemPipelinesSubscribedOnServer = false;
let systemPipelinesSubscriptionOperation: SubscriptionOperation | null = null;
let nodesSubscribed = false;
let nodesSubscribePending = false;
let nodesSubscribedOnServer = false;
let nodesSubscriptionOperation: SubscriptionOperation | null = null;
const statsListeners = new Set<Listener>();
const systemPipelinesListeners = new Set<Listener>();
const nodesListeners = new Set<Listener>();
const itemSubscriptions = new Map<string, ItemSubscription>();
const itemSubscriptionsOnServer = new Set<string>();
const itemSubscriptionOperations = new Map<string, SubscriptionOperation>();
const itemSourceListeners = new Map<string, Set<Listener>>();
const routeEventsListeners = new Map<string, Set<Listener>>();
const routeEventsSubscriptionsOnServer = new Set<string>();
const routeEventsSubscriptionOperations = new Map<string, SubscriptionOperation>();
const endpointHealthListeners = new Map<string, Set<Listener>>();

/**
 * Same rules as the pre-refactor UI (e.g. RouteItem): pass the HTTP `/socket`
 * endpoint into Phoenix; it appends `/websocket` itself.
 *
 * When API_BASE_URL shares the page origin (typical Vite dev: UI on :5173 and
 * constants fall back to pageOrigin), use a relative `/socket` so the dev
 * server can proxy WebSocket upgrades to Phoenix (see vite.config.ts).
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

const reconcileStatsSubscription = () => {
  if (!channel || !channelJoined || channelJoinInFlight || statsSubscriptionOperation) {
    return;
  }

  const shouldBeSubscribed = statsSubscribed;
  if (shouldBeSubscribed === statsSubscribedOnServer) {
    return;
  }

  const operation: SubscriptionOperation = {
    action: shouldBeSubscribed ? 'subscribe' : 'unsubscribe',
  };
  statsSubscribePending = false;
  statsSubscriptionOperation = operation;

  channel
    .push(`stats:${operation.action}`, {})
    .receive('ok', () => {
      if (statsSubscriptionOperation !== operation) {
        return;
      }

      statsSubscriptionOperation = null;
      statsSubscribedOnServer = operation.action === 'subscribe';
      reconcileStatsSubscription();
    })
    .receive('error', (error: unknown) => {
      if (statsSubscriptionOperation !== operation) {
        return;
      }

      statsSubscriptionOperation = null;
      const desiredChanged = operation.action === 'subscribe' ? !statsSubscribed : statsSubscribed;
      if (desiredChanged) {
        reconcileStatsSubscription();
      }
      console.error(`[realtime] stats ${operation.action} failed`, error);
    });
};

const reconcileSystemPipelinesSubscription = () => {
  if (!channel || !channelJoined || channelJoinInFlight || systemPipelinesSubscriptionOperation) {
    return;
  }

  const shouldBeSubscribed = systemPipelinesSubscribed;
  if (shouldBeSubscribed === systemPipelinesSubscribedOnServer) {
    return;
  }

  const operation: SubscriptionOperation = {
    action: shouldBeSubscribed ? 'subscribe' : 'unsubscribe',
  };
  systemPipelinesSubscribePending = false;
  systemPipelinesSubscriptionOperation = operation;

  channel
    .push(`system_pipelines:${operation.action}`, {})
    .receive('ok', () => {
      if (systemPipelinesSubscriptionOperation !== operation) {
        return;
      }

      systemPipelinesSubscriptionOperation = null;
      systemPipelinesSubscribedOnServer = operation.action === 'subscribe';
      reconcileSystemPipelinesSubscription();
    })
    .receive('error', (error: unknown) => {
      if (systemPipelinesSubscriptionOperation !== operation) {
        return;
      }

      systemPipelinesSubscriptionOperation = null;
      const desiredChanged = operation.action === 'subscribe'
        ? !systemPipelinesSubscribed
        : systemPipelinesSubscribed;
      if (desiredChanged) {
        reconcileSystemPipelinesSubscription();
      }
      console.error(`[realtime] system pipelines ${operation.action} failed`, error);
    });
};

const reconcileNodesSubscription = () => {
  if (!channel || !channelJoined || channelJoinInFlight || nodesSubscriptionOperation) {
    return;
  }

  const shouldBeSubscribed = nodesSubscribed;
  if (shouldBeSubscribed === nodesSubscribedOnServer) {
    return;
  }

  const operation: SubscriptionOperation = {
    action: shouldBeSubscribed ? 'subscribe' : 'unsubscribe',
  };
  nodesSubscribePending = false;
  nodesSubscriptionOperation = operation;

  channel
    .push(`nodes:${operation.action}`, {})
    .receive('ok', () => {
      if (nodesSubscriptionOperation !== operation) {
        return;
      }

      nodesSubscriptionOperation = null;
      nodesSubscribedOnServer = operation.action === 'subscribe';
      reconcileNodesSubscription();
    })
    .receive('error', (error: unknown) => {
      if (nodesSubscriptionOperation !== operation) {
        return;
      }

      nodesSubscriptionOperation = null;
      const desiredChanged = operation.action === 'subscribe' ? !nodesSubscribed : nodesSubscribed;
      if (desiredChanged) {
        reconcileNodesSubscription();
      }
      console.error(`[realtime] nodes ${operation.action} failed`, error);
    });
};

const reconcileItemSubscription = (itemId: string) => {
  if (!channel || !channelJoined || channelJoinInFlight || itemSubscriptionOperations.has(itemId)) {
    return;
  }

  const shouldBeSubscribed = itemSubscriptions.has(itemId);
  const subscribedOnServer = itemSubscriptionsOnServer.has(itemId);
  if (shouldBeSubscribed === subscribedOnServer) {
    return;
  }

  const operation: SubscriptionOperation = {
    action: shouldBeSubscribed ? 'subscribe' : 'unsubscribe',
  };
  itemSubscriptionOperations.set(itemId, operation);

  channel
    .push(`item:${operation.action}`, { item_id: itemId })
    .receive('ok', () => {
      if (itemSubscriptionOperations.get(itemId) !== operation) {
        return;
      }

      itemSubscriptionOperations.delete(itemId);
      if (operation.action === 'subscribe') {
        itemSubscriptionsOnServer.add(itemId);
      } else {
        itemSubscriptionsOnServer.delete(itemId);
      }
      reconcileItemSubscription(itemId);
    })
    .receive('error', (error: unknown) => {
      if (itemSubscriptionOperations.get(itemId) !== operation) {
        return;
      }

      itemSubscriptionOperations.delete(itemId);
      const desiredChanged = operation.action === 'subscribe'
        ? !itemSubscriptions.has(itemId)
        : itemSubscriptions.has(itemId);
      if (desiredChanged) {
        reconcileItemSubscription(itemId);
      }
      console.error(`[realtime] item ${operation.action} failed`, itemId, error);
    });
};

const reconcileRouteEventsSubscription = (routeId: string) => {
  if (!channel || !channelJoined || channelJoinInFlight || routeEventsSubscriptionOperations.has(routeId)) {
    return;
  }

  const shouldBeSubscribed = routeEventsListeners.has(routeId);
  const subscribedOnServer = routeEventsSubscriptionsOnServer.has(routeId);
  if (shouldBeSubscribed === subscribedOnServer) {
    return;
  }

  const operation: SubscriptionOperation = {
    action: shouldBeSubscribed ? 'subscribe' : 'unsubscribe',
  };
  routeEventsSubscriptionOperations.set(routeId, operation);

  channel
    .push(`events:${operation.action}`, { route_id: routeId })
    .receive('ok', () => {
      if (routeEventsSubscriptionOperations.get(routeId) !== operation) {
        return;
      }

      routeEventsSubscriptionOperations.delete(routeId);
      if (operation.action === 'subscribe') {
        routeEventsSubscriptionsOnServer.add(routeId);
      } else {
        routeEventsSubscriptionsOnServer.delete(routeId);
      }
      reconcileRouteEventsSubscription(routeId);
    })
    .receive('error', (error: unknown) => {
      if (routeEventsSubscriptionOperations.get(routeId) !== operation) {
        return;
      }

      routeEventsSubscriptionOperations.delete(routeId);
      const desiredChanged = operation.action === 'subscribe'
        ? !routeEventsListeners.has(routeId)
        : routeEventsListeners.has(routeId);
      if (desiredChanged) {
        reconcileRouteEventsSubscription(routeId);
      }
      console.error(`[realtime] events ${operation.action} failed`, routeId, error);
    });
};

const pushStatsSubscription = () => {
  if (!statsSubscribed) {
    return;
  }

  statsSubscribePending = true;
  reconcileStatsSubscription();
};

const pushStatsUnsubscription = () => {
  statsSubscribePending = false;
  reconcileStatsSubscription();
};

const pushSystemPipelinesSubscription = () => {
  if (!systemPipelinesSubscribed) {
    return;
  }

  systemPipelinesSubscribePending = true;
  reconcileSystemPipelinesSubscription();
};

const pushSystemPipelinesUnsubscription = () => {
  systemPipelinesSubscribePending = false;
  reconcileSystemPipelinesSubscription();
};

const pushNodesSubscription = () => {
  if (!nodesSubscribed) {
    return;
  }

  nodesSubscribePending = true;
  reconcileNodesSubscription();
};

const pushNodesUnsubscription = () => {
  nodesSubscribePending = false;
  reconcileNodesSubscription();
};

const addItemListener = (itemId: string, listener?: Listener) => {
  const current = itemSubscriptions.get(itemId) || { listeners: new Set(), refCount: 0 };

  if (typeof listener === 'function') {
    current.listeners.add(listener);
  }

  current.refCount += 1;
  itemSubscriptions.set(itemId, current);
};

const removeItemListener = (itemId: string, listener?: Listener) => {
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

const pushItemSubscription = (itemId: string) => {
  if (!itemId || !itemSubscriptions.has(itemId)) {
    return;
  }

  reconcileItemSubscription(itemId);
};

const pushItemUnsubscription = (itemId: string) => {
  reconcileItemSubscription(itemId);
};

const pushAllItemSubscriptions = () => {
  Array.from(itemSubscriptions.keys()).forEach((itemId) => {
    pushItemSubscription(itemId);
  });
};

const pushRouteEventsSubscription = (routeId: string) => {
  if (!routeId || !routeEventsListeners.has(routeId)) {
    return;
  }

  reconcileRouteEventsSubscription(routeId);
};

const pushRouteEventsUnsubscription = (routeId: string) => {
  reconcileRouteEventsSubscription(routeId);
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
  statsSubscriptionOperation = null;
  systemPipelinesSubscribedOnServer = false;
  systemPipelinesSubscriptionOperation = null;
  nodesSubscribedOnServer = false;
  nodesSubscriptionOperation = null;
  itemSubscriptionsOnServer.clear();
  itemSubscriptionOperations.clear();
  routeEventsSubscriptionsOnServer.clear();
  routeEventsSubscriptionOperations.clear();
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

  channel.on('stats', (payload: Payload) => {
    statsListeners.forEach((listener) => listener(payload));
  });

  channel.on('system_pipelines', (payload: Payload) => {
    systemPipelinesListeners.forEach((listener) => listener(payload));
  });

  channel.on('nodes', (payload: Payload) => {
    nodesListeners.forEach((listener) => listener(payload));
  });

  channel.on('item_status', (payload: Payload) => {
    const itemId = typeof payload?.item_id === 'string' ? payload.item_id : null;

    if (!itemId) {
      return;
    }

    const listeners = itemSubscriptions.get(itemId)?.listeners;

    if (!listeners || listeners.size === 0) {
      return;
    }

    listeners.forEach((listener) => listener(payload));
  });

  channel.on('item_source', (payload: Payload) => {
    const itemId = typeof payload?.item_id === 'string' ? payload.item_id : null;

    if (!itemId) {
      return;
    }

    const listeners = itemSourceListeners.get(itemId);

    if (!listeners || listeners.size === 0) {
      return;
    }

    listeners.forEach((listener) => listener(payload));
  });

  channel.on('event', (payload: Payload) => {
    const routeId = typeof payload?.route_id === 'string' ? payload.route_id : null;

    if (!routeId) {
      return;
    }

    const listeners = routeEventsListeners.get(routeId);

    if (!listeners || listeners.size === 0) {
      return;
    }

    listeners.forEach((listener) => listener(payload));
  });

  channel.on('endpoint_health', (payload: Payload) => {
    const routeId = typeof payload?.route_id === 'string' ? payload.route_id : null;

    if (!routeId) {
      return;
    }

    const listeners = endpointHealthListeners.get(routeId);

    if (!listeners || listeners.size === 0) {
      return;
    }

    listeners.forEach((listener) => listener(payload));
  });

  channel.onError((error: unknown) => {
    console.error('[realtime] channel error', error);
  });

  channel.onClose(() => {
    channelJoined = false;
    channelJoinInFlight = false;
    statsSubscribedOnServer = false;
    statsSubscriptionOperation = null;
    systemPipelinesSubscribedOnServer = false;
    systemPipelinesSubscriptionOperation = null;
    nodesSubscribedOnServer = false;
    nodesSubscriptionOperation = null;
    itemSubscriptionsOnServer.clear();
    itemSubscriptionOperations.clear();
    routeEventsSubscriptionsOnServer.clear();
    routeEventsSubscriptionOperations.clear();
  });

  socket.onOpen(() => {
    console.debug('[realtime] socket connected');
  });

  socket.onError((error: unknown) => {
    console.error('[realtime] socket transport error', error);
  });

  socket.onClose(() => {
    channelJoined = false;
    channelJoinInFlight = false;
    statsSubscribedOnServer = false;
    statsSubscriptionOperation = null;
    systemPipelinesSubscribedOnServer = false;
    systemPipelinesSubscriptionOperation = null;
    nodesSubscribedOnServer = false;
    nodesSubscriptionOperation = null;
    itemSubscriptionsOnServer.clear();
    itemSubscriptionOperations.clear();
    routeEventsSubscriptionsOnServer.clear();
    routeEventsSubscriptionOperations.clear();
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
    .receive('error', (error: unknown) => {
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
  statsSubscriptionOperation = null;
  systemPipelinesSubscribed = false;
  systemPipelinesSubscribePending = false;
  systemPipelinesSubscribedOnServer = false;
  systemPipelinesSubscriptionOperation = null;
  nodesSubscribed = false;
  nodesSubscribePending = false;
  nodesSubscribedOnServer = false;
  nodesSubscriptionOperation = null;
  statsListeners.clear();
  systemPipelinesListeners.clear();
  nodesListeners.clear();
  itemSubscriptions.clear();
  itemSubscriptionsOnServer.clear();
  itemSubscriptionOperations.clear();
  itemSourceListeners.clear();
  routeEventsListeners.clear();
  routeEventsSubscriptionsOnServer.clear();
  routeEventsSubscriptionOperations.clear();
  endpointHealthListeners.clear();
};

export const subscribeToStats = (listener: Listener) => {
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

export const subscribeToNodes = (listener: Listener) => {
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

export const subscribeToSystemPipelines = (listener: Listener) => {
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

export const subscribeToItemStatus = (itemId: string, listener: Listener) => {
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

export const subscribeToItemSource = (itemId: string, listener: Listener) => {
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

export const subscribeToRouteEvents = (routeId: string, listener: Listener) => {
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

/**
 * Subscribe to NDI `endpoint_health` pushes for a route.
 * Uses the existing item channel subscription so the server can forward
 * PubSub `{:endpoint_health, payload}` as `endpoint_health` events.
 */
export const subscribeToEndpointHealth = (routeId: string, listener: Listener) => {
  if (typeof routeId !== 'string' || routeId.length === 0) {
    return () => {};
  }

  const listeners = endpointHealthListeners.get(routeId) || new Set();

  if (typeof listener === 'function') {
    listeners.add(listener);
  }

  endpointHealthListeners.set(routeId, listeners);
  connectRealtime();
  addItemListener(routeId);
  pushItemSubscription(routeId);

  return () => {
    const currentListeners = endpointHealthListeners.get(routeId);

    if (currentListeners && typeof listener === 'function') {
      currentListeners.delete(listener);
    }

    if (!currentListeners || currentListeners.size === 0) {
      endpointHealthListeners.delete(routeId);
      const remaining = removeItemListener(routeId);
      if (remaining === 0) {
        pushItemUnsubscription(routeId);
      }
    } else {
      endpointHealthListeners.set(routeId, currentListeners);
    }
  };
};
