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
const statsListeners = new Set();

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

export const connectRealtime = () => {
  const token = getToken();

  if (!token) {
    disconnectRealtime();
    return null;
  }

  if (socket && currentToken === token) {
    return channel;
  }

  disconnectRealtime();
  currentToken = token;
  socket = new Socket(getSocketEndpoint(), { params: { token } });
  channel = socket.channel('realtime');
  channelJoined = false;
  channelJoinInFlight = true;
  statsSubscribedOnServer = false;

  channel.on('stats', (payload) => {
    statsListeners.forEach((listener) => listener(payload));
  });

  channel.onError((error) => {
    console.error('[realtime] channel error', error);
  });

  channel.onClose(() => {
    channelJoined = false;
    channelJoinInFlight = false;
    statsSubscribedOnServer = false;
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
    })
    .receive('error', (error) => {
      channelJoinInFlight = false;
      console.error('[realtime] channel join failed', error);
    });

  return channel;
};

export const disconnectRealtime = () => {
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
  statsSubscribed = false;
  statsSubscribePending = false;
  statsSubscribedOnServer = false;
  statsListeners.clear();
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
