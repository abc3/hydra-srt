import { describe, expect, it } from 'vitest';
import { flattenEndpointPayload, normalizeEndpointForForm } from '../endpointOptions';

describe('endpointOptions', () => {
  it('normalizes IP access list strings to arrays', () => {
    const endpoint = normalizeEndpointForForm({
      schema: 'SRT',
      mode: 'listener',
      allowed_list: '127.0.0.1, 10.10.0.0/16\n127.0.0.1',
      denied_list: [' 192.0.2.10 ', ''],
    });

    expect(endpoint?.allowed_list).toEqual(['127.0.0.1', '10.10.0.0/16']);
    expect(endpoint?.denied_list).toEqual(['192.0.2.10']);
    expect(endpoint?.limit_access).toBe(false);
  });

  it('preserves IP access list arrays in flattened payloads', () => {
    const payload = flattenEndpointPayload({
      schema: 'SRT',
      mode: 'listener',
      limit_access: true,
      allowed_list: ['127.0.0.1'],
      denied_list: ['192.0.2.10'],
    });

    expect(payload?.limit_access).toBe(true);
    expect(payload?.allowed_list).toEqual(['127.0.0.1']);
    expect(payload?.denied_list).toEqual(['192.0.2.10']);
  });

  it('normalizes UDP source host to address and defaults multicast off', () => {
    const endpoint = normalizeEndpointForForm({
      schema: 'UDP',
      host: '239.1.1.1',
      port: '5000',
    });

    expect(endpoint?.address).toBe('239.1.1.1');
    expect(endpoint?.port).toBe(5000);
    expect(endpoint?.multicast).toBe(false);
  });

  it('preserves explicit multicast source fields in flattened payloads', () => {
    const payload = flattenEndpointPayload({
      schema: 'RTP',
      address: '239.1.1.2',
      port: 5004,
      multicast: true,
      interface_sys_name: 'en0',
      multicast_iface: 'en0',
    });

    expect(payload?.address).toBe('239.1.1.2');
    expect(payload?.multicast).toBe(true);
    expect(payload?.interface_sys_name).toBe('en0');
    expect(payload?.multicast_iface).toBe('en0');
  });

  it('preserves a selected MPEG-TS program in source payloads', () => {
    const payload = flattenEndpointPayload({
      schema: 'UDP',
      address: '239.1.1.2',
      port: 5000,
      program_number: 12,
    });

    expect(payload?.program_number).toBe(12);
  });

  it('omits an empty or destination MPEG-TS program value', () => {
    expect(flattenEndpointPayload({ schema: 'RTP', program_number: null })?.program_number).toBeUndefined();
    expect(flattenEndpointPayload({ schema: 'RTMP', program_number: 12 })?.program_number).toBeUndefined();
    expect(flattenEndpointPayload({ schema: 'NDI', program_number: 12 })?.program_number).toBeUndefined();
  });

  it('sends null when a selected interface is cleared', () => {
    const payload = flattenEndpointPayload({
      schema: 'SRT',
      mode: 'listener',
      interface_sys_name: undefined,
      localaddress: '0.0.0.0',
      localport: 9100,
    });

    expect(payload?.interface_sys_name).toBeNull();
  });

  it('preserves streamid through API normalization and flattening', () => {
    const endpoint = normalizeEndpointForForm({
      schema: 'SRT',
      mode: 'caller',
      address: '198.51.100.20',
      port: 4209,
      streamid: '#!::r=channel',
    });

    expect(endpoint?.streamid).toBe('#!::r=channel');
    expect(flattenEndpointPayload(endpoint)?.streamid).toBe('#!::r=channel');
  });

  it('normalizes NDI discovery fields and strips client-owned snapshots on flatten', () => {
    const endpoint = normalizeEndpointForForm({
      schema: 'NDI',
      ndi_selection_mode: 'discovery_name',
      ndi_source_name: ' CAM (A) ',
      ndi_source_address: 'should-clear',
      ndi_observed_address_snapshot: '192.0.2.1:5961',
      selection_token: 'tok-should-not-persist-in-form',
      ndi_connect_timeout_ms: '500',
      ndi_max_queue_length: 99,
    });

    expect(endpoint?.ndi_selection_mode).toBe('discovery_name');
    expect(endpoint?.ndi_source_name).toBe('CAM (A)');
    expect(endpoint?.ndi_source_address).toBeNull();
    expect(endpoint?.selection_token).toBeUndefined();
    expect(endpoint?.ndi_connect_timeout_ms).toBe(1000);
    expect(endpoint?.ndi_max_queue_length).toBe(64);
    expect(endpoint?.ndi_bandwidth).toBe('highest');

    const payload = flattenEndpointPayload({
      ...endpoint,
      selection_token: 'fresh-token',
      ndi_observed_address_snapshot: '192.0.2.1:5961',
    });

    expect(payload?.selection_token).toBe('fresh-token');
    expect(payload?.ndi_observed_address_snapshot).toBeUndefined();
    expect(payload?.ndi_source_name).toBe('CAM (A)');
  });

  it('normalizes NDI direct-address mode and clears discovery name', () => {
    const payload = flattenEndpointPayload({
      schema: 'NDI',
      ndi_selection_mode: 'direct_address',
      ndi_source_address: '192.0.2.9:5961',
      ndi_source_name: 'should-clear',
      selection_token: 'tok',
    });

    expect(payload?.ndi_selection_mode).toBe('direct_address');
    expect(payload?.ndi_source_address).toBe('192.0.2.9:5961');
    expect(payload?.ndi_source_name).toBeNull();
    expect(payload?.selection_token).toBeUndefined();
  });
});
