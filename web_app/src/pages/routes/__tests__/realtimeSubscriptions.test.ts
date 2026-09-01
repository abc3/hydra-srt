import { beforeEach, describe, expect, it, vi } from 'vitest';

type Push = {
  receive: (status: string, callback: (payload: unknown) => void) => Push;
  resolve: (status: string, payload?: unknown) => void;
};

const phoenixMock = vi.hoisted(() => {
  const pushes: Array<{ event: string; payload: Record<string, unknown>; push: Push }> = [];
  const serverSubscriptions = new Set<string>();
  let joinPush: Push | null = null;

  const makePush = (): Push => {
    const callbacks = new Map<string, (payload: unknown) => void>();
    const push: Push = {
      receive: (status, callback) => {
        callbacks.set(status, callback);
        return push;
      },
      resolve: (status, payload = {}) => {
        callbacks.get(status)?.(payload);
      },
    };
    return push;
  };

  const channel = {
    join: vi.fn(() => {
      joinPush = makePush();
      return joinPush;
    }),
    leave: vi.fn(),
    on: vi.fn(),
    onClose: vi.fn(),
    onError: vi.fn(),
    push: vi.fn((event: string, payload: Record<string, unknown>) => {
      const push = makePush();
      pushes.push({ event, payload, push });
      return push;
    }),
  };

  class MockSocket {
    channel = vi.fn(() => channel);
    connect = vi.fn();
    disconnect = vi.fn();
    onOpen = vi.fn();
    onError = vi.fn();
    onClose = vi.fn();
  }

  return {
    Socket: MockSocket,
    channel,
    pushes,
    serverSubscriptions,
    resolveJoin: () => joinPush?.resolve('ok'),
    resolvePush: (index: number, status = 'ok') => {
      const pending = pushes[index];
      pending?.push.resolve(status);
      if (status === 'ok' && pending) {
        const itemId = String(pending.payload.item_id || pending.payload.route_id || '');
        if (pending.event.endsWith(':subscribe')) {
          serverSubscriptions.add(itemId);
        } else if (pending.event.endsWith(':unsubscribe')) {
          serverSubscriptions.delete(itemId);
        }
      }
    },
    reset: () => {
      pushes.length = 0;
      serverSubscriptions.clear();
      joinPush = null;
      channel.join.mockClear();
      channel.leave.mockClear();
      channel.on.mockClear();
      channel.onClose.mockClear();
      channel.onError.mockClear();
      channel.push.mockClear();
    },
  };
});

vi.mock('phoenix', () => ({ Socket: phoenixMock.Socket }));

import * as realtime from '../../../utils/realtime';

const tokenStorage = {
  getItem: (key: string) => (key === 'token' ? 'test-token' : null),
  setItem: vi.fn(),
  removeItem: vi.fn(),
};

const subscriptionCases = [
  {
    name: 'item status',
    subscribe: (listener: (payload: Record<string, unknown>) => void) =>
      realtime.subscribeToItemStatus('route-1', listener),
    subscribeEvent: 'item:subscribe',
    unsubscribeEvent: 'item:unsubscribe',
  },
  {
    name: 'route events',
    subscribe: (listener: (payload: Record<string, unknown>) => void) =>
      realtime.subscribeToRouteEvents('route-1', listener),
    subscribeEvent: 'events:subscribe',
    unsubscribeEvent: 'events:unsubscribe',
  },
  {
    name: 'stats',
    subscribe: (listener: (payload: Record<string, unknown>) => void) => realtime.subscribeToStats(listener),
    subscribeEvent: 'stats:subscribe',
    unsubscribeEvent: 'stats:unsubscribe',
  },
  {
    name: 'system pipelines',
    subscribe: (listener: (payload: Record<string, unknown>) => void) => realtime.subscribeToSystemPipelines(listener),
    subscribeEvent: 'system_pipelines:subscribe',
    unsubscribeEvent: 'system_pipelines:unsubscribe',
  },
  {
    name: 'nodes',
    subscribe: (listener: (payload: Record<string, unknown>) => void) => realtime.subscribeToNodes(listener),
    subscribeEvent: 'nodes:subscribe',
    unsubscribeEvent: 'nodes:unsubscribe',
  },
];

describe('realtime subscription bookkeeping', () => {
  beforeEach(() => {
    realtime.disconnectRealtime();
    phoenixMock.reset();
    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      value: tokenStorage,
    });
  });

  it.each(subscriptionCases)('$name remains subscribed after a racing resubscribe', ({
    subscribe,
    subscribeEvent,
    unsubscribeEvent,
  }) => {
    const firstListener = vi.fn();
    const unsubscribe = subscribe(firstListener);

    phoenixMock.resolveJoin();
    expect(phoenixMock.pushes.map(({ event }) => event)).toEqual([subscribeEvent]);
    phoenixMock.resolvePush(0);

    unsubscribe();
    expect(phoenixMock.pushes.map(({ event }) => event)).toEqual([subscribeEvent, unsubscribeEvent]);

    const secondListener = vi.fn();
    subscribe(secondListener);
    expect(phoenixMock.pushes.map(({ event }) => event)).toEqual([subscribeEvent, unsubscribeEvent]);

    phoenixMock.resolvePush(1);
    expect(phoenixMock.pushes.map(({ event }) => event)).toEqual([
      subscribeEvent,
      unsubscribeEvent,
      subscribeEvent,
    ]);

    phoenixMock.resolvePush(2);
    expect(phoenixMock.serverSubscriptions.size).toBe(1);
  });
});
