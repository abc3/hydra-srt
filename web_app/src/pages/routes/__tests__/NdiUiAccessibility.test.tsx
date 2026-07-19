import { render, screen } from '@testing-library/react';
import { Form } from 'antd';
import { describe, expect, it, vi } from 'vitest';
import NdiTrademarkNotice from '../NdiTrademarkNotice';
import NdiCapabilityAlert from '../NdiCapabilityAlert';
import NdiOutputFields from '../NdiOutputFields';
import type { NdiCapabilities } from '../../../types/ndi';

vi.mock('../../../utils/ndiApi', () => ({
  ndiApi: {
    listSources: vi.fn(async () => ({ data: [], meta: {} })),
  },
}));

const availableCaps = (): NdiCapabilities => ({
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
});

describe('NDI trademark and capability UI', () => {
  it('renders trademark text with ndi.video link and no pre-checked checkbox', () => {
    render(<NdiTrademarkNotice />);
    expect(screen.getByText(/NDI® is a registered trademark/i)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'ndi.video' })).toHaveAttribute('href', 'https://ndi.video');
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  });

  it('shows configured non-runnable status with icon and text, not color alone', () => {
    const caps = availableCaps();
    caps.receive = { available: false, reason_codes: ['NDI_RUNTIME_MISSING'], formats: [] };
    caps.runtime = { available: false, major: null, version: null };

    render(<NdiCapabilityAlert capabilities={caps} direction="receive" />);

    // Status has to be readable as text, not signalled by colour alone, in plain
    // language, and stated once: no second hand-rolled warning repeating it.
    expect(screen.getByText(/NDI runtime is not installed/i)).toBeInTheDocument();
    expect(screen.queryByText(/NDI_RUNTIME_MISSING/)).not.toBeInTheDocument();
    expect(screen.queryByText(/non-runnable/i)).not.toBeInTheDocument();
    expect(screen.getByRole('status')).toBeInTheDocument();
  });

  it('renders output format statement and React-escaped sender names', () => {
    render(
      <Form initialValues={{ ndi_sender_name: '<script>x</script>' }}>
        <NdiOutputFields capabilities={availableCaps()} />
      </Form>,
    );

    expect(screen.getByText('NDI High Bandwidth (SDR)')).toBeInTheDocument();
    expect(screen.getByDisplayValue('<script>x</script>')).toBeInTheDocument();
    expect(document.body.innerHTML).not.toContain('<script>x</script></script>');
  });
});
