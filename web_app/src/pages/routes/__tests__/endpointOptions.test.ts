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
});
