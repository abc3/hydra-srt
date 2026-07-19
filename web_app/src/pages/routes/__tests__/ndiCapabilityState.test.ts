import { describe, expect, it } from 'vitest';
import type { NdiCapabilities } from '../../../types/ndi';
import {
  deriveNdiCapabilityUiState,
  isNdiRunnable,
  primaryReasonCode,
  reasonCodeExplanation,
} from '../ndiCapabilityState';
import { listSelectableProtocols } from '../../../utils/protocolCapabilities';

const baseCapabilities = (overrides: Partial<NdiCapabilities> = {}): NdiCapabilities => ({
  node_id: 'self',
  feature_enabled: true,
  plugin: { available: true, revision: 'pinned' },
  runtime: { available: true, major: 6, version: '6.0.0' },
  receive: { available: true, reason_codes: [], formats: ['uyvy-bgra'] },
  send: { available: true, reason_codes: [], formats: ['uyvy-bgra'] },
  discovery: { available: true, reason_codes: [], mode: 'mdns' },
  direct_address: { available: true, reason_codes: [] },
  checked_at: '2026-07-19T00:00:00Z',
  expires_at: '2026-07-19T00:00:15Z',
  stale: false,
  check_in_progress: false,
  ...overrides,
});

describe('ndiCapabilityState', () => {
  it('maps loading and disabled feature states', () => {
    expect(deriveNdiCapabilityUiState(null, { loading: true })).toBe('checking');
    expect(deriveNdiCapabilityUiState(baseCapabilities({ feature_enabled: false }))).toBe('feature-disabled');
  });

  it('maps reason-code families to UI states', () => {
    expect(
      deriveNdiCapabilityUiState(
        baseCapabilities({
          receive: { available: false, reason_codes: ['NDI_PLUGIN_MISSING'], formats: [] },
        }),
      ),
    ).toBe('plugin-missing');

    expect(
      deriveNdiCapabilityUiState(
        baseCapabilities({
          receive: { available: false, reason_codes: ['NDI_RUNTIME_MISSING'], formats: [] },
        }),
      ),
    ).toBe('runtime-missing-or-incompatible');

    expect(
      deriveNdiCapabilityUiState(
        baseCapabilities({
          receive: { available: false, reason_codes: ['NDI_CPU_UNSUPPORTED'], formats: [] },
        }),
      ),
    ).toBe('platform-CPU-unsupported');

    expect(
      deriveNdiCapabilityUiState(
        baseCapabilities({
          discovery: { available: false, reason_codes: ['NDI_AVAHI_UNAVAILABLE'], mode: 'mdns' },
        }),
        { direction: 'discovery' },
      ),
    ).toBe('discovery-prerequisite-unavailable');

    expect(
      deriveNdiCapabilityUiState(baseCapabilities({ check_in_progress: true })),
    ).toBe('helper-restarting');

    expect(deriveNdiCapabilityUiState(baseCapabilities({ stale: true }))).toBe('stale');
  });

  it('disables Test/Start runnability while still explaining the reason', () => {
    const caps = baseCapabilities({
      runtime: { available: false, major: null, version: null },
      receive: { available: false, reason_codes: ['NDI_RUNTIME_MISSING'], formats: [] },
    });

    expect(isNdiRunnable(caps, 'receive')).toBe(false);
    expect(primaryReasonCode(caps.receive.reason_codes)).toBe('NDI_RUNTIME_MISSING');
    expect(reasonCodeExplanation('NDI_RUNTIME_MISSING')).toMatch(/runtime is not installed/i);
  });
});

describe('protocolCapabilities', () => {
  it('shows NDI only when the feature flag is enabled', () => {
    expect(listSelectableProtocols('source', { ndiFeatureEnabled: false }).map((p) => p.schema)).not.toContain('NDI');
    expect(listSelectableProtocols('source', { ndiFeatureEnabled: true }).map((p) => p.schema)).toContain('NDI');
    expect(listSelectableProtocols('destination', { ndiFeatureEnabled: true }).map((p) => p.schema)).toContain('NDI');
    expect(listSelectableProtocols('destination', { ndiFeatureEnabled: true }).map((p) => p.schema)).not.toContain('RTP');
  });
});
