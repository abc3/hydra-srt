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

    expect(endpoint.allowed_list).toEqual(['127.0.0.1', '10.10.0.0/16']);
    expect(endpoint.denied_list).toEqual(['192.0.2.10']);
    expect(endpoint.limit_access).toBe(false);
  });

  it('preserves IP access list arrays in flattened payloads', () => {
    const payload = flattenEndpointPayload({
      schema: 'SRT',
      mode: 'listener',
      limit_access: true,
      allowed_list: ['127.0.0.1'],
      denied_list: ['192.0.2.10'],
    });

    expect(payload.limit_access).toBe(true);
    expect(payload.allowed_list).toEqual(['127.0.0.1']);
    expect(payload.denied_list).toEqual(['192.0.2.10']);
  });
});
