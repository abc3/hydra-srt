import { describe, expect, it } from 'vitest';
import type { RouteEndpoint, RouteRecord } from '../../../types/routes';
import {
  buildCloneName,
  buildRouteClone,
  CLONE_NAME_PREFIX,
} from '../routeClone';

const endpoint = (fields: Record<string, unknown>): RouteEndpoint => ({
  id: 'endpoint-id',
  route_id: 'route-id',
  position: 0,
  status: 'connected',
  schema_status: 'ready',
  ...fields,
});

const route = (fields: Record<string, unknown> = {}): RouteRecord => ({
  id: 'route-id',
  name: 'Route 1',
  enabled: true,
  ...fields,
});

describe('buildCloneName', () => {
  it('prefixes names without duplicating the clone prefix', () => {
    expect(buildCloneName(' Route 1 ')).toBe('CLONE - Route 1');
    expect(buildCloneName(`${CLONE_NAME_PREFIX}Route 1`)).toBe(`${CLONE_NAME_PREFIX}Route 1`);
  });

  it('returns the prefix for blank or missing names', () => {
    expect(buildCloneName('   ')).toBe(CLONE_NAME_PREFIX);
    expect(buildCloneName(null)).toBe(CLONE_NAME_PREFIX);
    expect(buildCloneName(undefined)).toBe(CLONE_NAME_PREFIX);
  });
});

describe('buildRouteClone', () => {
  it('removes route identity and runtime fields while preserving configuration', () => {
    const source = route({
      status: 'running',
      schema_status: 'ready',
      started_at: 'started',
      stopped_at: 'stopped',
      active_source_id: 'source-id',
      last_switch_reason: 'manual',
      last_switch_at: 'switched',
      lock_version: 3,
      inserted_at: 'inserted',
      updated_at: 'updated',
      node: 'node-1',
      gstDebug: true,
      tags: ['news'],
      backup_mode: 'active',
      backup_switch_after_ms: 5000,
    });

    const { route: clone } = buildRouteClone(source);

    expect(clone).toMatchObject({
      name: 'CLONE - Route 1',
      enabled: false,
      node: 'node-1',
      gstDebug: true,
      tags: ['news'],
      backup_mode: 'active',
      backup_switch_after_ms: 5000,
    });
    expect(clone.tags).not.toBe(source.tags);

    for (const key of [
      'id',
      'status',
      'schema_status',
      'started_at',
      'stopped_at',
      'active_source_id',
      'last_switch_reason',
      'last_switch_at',
      'lock_version',
      'inserted_at',
      'updated_at',
    ]) {
      expect(clone).not.toHaveProperty(key);
    }
  });

  it('strips endpoint identity fields and preserves endpoint configuration', () => {
    const sourceEndpoint = endpoint({
      localport: '5000',
      port: 5001,
      address: '239.0.0.1',
      passphrase: 'secret',
      mode: 'listener',
      schema: 'SRT',
    });
    const { route: clone } = buildRouteClone(route({ sources: [sourceEndpoint] }));
    const clonedEndpoint = clone.sources[0];

    expect(clonedEndpoint).toMatchObject({
      localport: '5000',
      port: 5001,
      address: '239.0.0.1',
      passphrase: 'secret',
      mode: 'listener',
      schema: 'SRT',
    });
    for (const key of [
      'id',
      'route_id',
      'position',
      'status',
      'schema_status',
      'started_at',
      'stopped_at',
      'lock_version',
      'inserted_at',
      'updated_at',
      'last_probe_at',
      'last_failure_at',
      'ndi_sender_name_key',
    ]) {
      expect(clonedEndpoint).not.toHaveProperty(key);
    }
  });

  it('sorts sources by original position and leaves destinations in API order', () => {
    const sources = [
      endpoint({ position: 2, name: 'third' }),
      endpoint({ position: 0, name: 'first' }),
      endpoint({ position: 1, name: 'second' }),
    ];
    const destinations = [endpoint({ name: 'second' }), endpoint({ name: 'first' })];
    const { route: clone } = buildRouteClone(route({ sources, destinations }));

    expect(clone.sources.map((item) => item.name)).toEqual(['first', 'second', 'third']);
    expect(clone.destinations.map((item) => item.name)).toEqual(['second', 'first']);
    expect(sources.map((item) => item.name)).toEqual(['third', 'first', 'second']);
  });

  it('does not mutate the input route or endpoints', () => {
    const source = endpoint({ position: 1, schema: 'NDI', ndi_sender_name: 'Sender' });
    const input = route({ sources: [source], destinations: [] });
    const inputSnapshot = structuredClone(input);

    buildRouteClone(input);

    expect(input).toEqual(inputSnapshot);
  });

  it.each([
    ['SRT listener source with localport', 'sources', { schema: 'SRT', mode: 'listener', localport: '4001' }],
    ['SRT rendezvous destination', 'destinations', { schema: 'SRT', mode: 'rendezvous', port: 4002 }],
    ['UDP source with port', 'sources', { schema: 'UDP', port: 4003 }],
    ['RTP source with port', 'sources', { schema: 'RTP', port: 4004 }],
    ['UDP destination with localport', 'destinations', { schema: 'UDP', localport: 4005 }],
  ] as const)('warns for a reserved bind target: %s', (_description, list, fields) => {
    const { warnings } = buildRouteClone(route({ [list]: [endpoint(fields)] }));

    expect(warnings).toEqual([
      expect.objectContaining({ list, index: 0, kind: 'bind_target' }),
    ]);
  });

  it.each([
    ['SRT caller destination with port', 'destinations', { schema: 'SRT', mode: 'caller', port: 4010 }],
    ['UDP destination without localport', 'destinations', { schema: 'UDP', port: 4011 }],
    ['RTP destination with localport', 'destinations', { schema: 'RTP', localport: 4012 }],
    ['RTMP destination', 'destinations', { schema: 'RTMP', port: 4012 }],
    ['NDI destination without a sender name', 'destinations', { schema: 'NDI' }],
    ['SRT listener with null port', 'sources', { schema: 'SRT', mode: 'listener', port: null }],
    ['SRT listener with blank port', 'sources', { schema: 'SRT', mode: 'listener', port: '' }],
  ] as const)('does not warn when no reservation applies: %s', (_description, list, fields) => {
    const { warnings } = buildRouteClone(route({ [list]: [endpoint(fields)] }));

    expect(warnings).toEqual([]);
  });

  it('prefixes and warns for an NDI destination sender name', () => {
    const { route: clone, warnings } = buildRouteClone(
      route({ destinations: [endpoint({ schema: ' nDi ', ndi_sender_name: ' Sender ' })] }),
    );

    expect(clone.destinations[0].ndi_sender_name).toBe('CLONE - Sender');
    expect(warnings).toEqual([
      { list: 'destinations', index: 0, name: 'Destination 1', kind: 'ndi_sender_name' },
    ]);
  });

  it('leaves missing or blank NDI sender names alone', () => {
    const destinations = [
      endpoint({ schema: 'NDI' }),
      endpoint({ schema: 'NDI', ndi_sender_name: '   ' }),
    ];
    const { route: clone, warnings } = buildRouteClone(route({ destinations }));

    expect(clone.destinations[0]).not.toHaveProperty('ndi_sender_name');
    expect(clone.destinations[1].ndi_sender_name).toBe('   ');
    expect(warnings).toEqual([]);
  });

  it('leaves an already-prefixed NDI sender name alone without warning', () => {
    const { route: clone, warnings } = buildRouteClone(
      route({ destinations: [endpoint({ schema: 'NDI', ndi_sender_name: 'CLONE - Sender' })] }),
    );

    expect(clone.destinations[0].ndi_sender_name).toBe('CLONE - Sender');
    expect(warnings).toEqual([]);
  });

  it('uses list labels when an endpoint has no non-blank name', () => {
    const { warnings } = buildRouteClone(
      route({
        sources: [
          endpoint({ name: 'Primary', schema: 'UDP', port: 4020 }),
          endpoint({ schema: 'UDP', port: 4021 }),
        ],
        destinations: [
          endpoint({ schema: 'SRT', mode: 'rendezvous', port: 4022 }),
          endpoint({ schema: 'SRT', mode: 'rendezvous', port: 4023 }),
        ],
      }),
    );

    expect(warnings.map(({ name }) => name)).toEqual([
      'Primary',
      'Source 2',
      'Destination 1',
      'Destination 2',
    ]);
  });

  it('returns empty lists and no warnings when a route has no endpoints', () => {
    const { route: clone, warnings } = buildRouteClone(route());

    expect(clone.sources).toEqual([]);
    expect(clone.destinations).toEqual([]);
    expect(warnings).toEqual([]);
  });
});
