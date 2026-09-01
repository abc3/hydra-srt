import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteSourceEdit from '../RouteSourceEdit';

const { mockRoutesApi, mockDestinationsApi, mockInterfacesApi, mockSourcesApi, mockTagsApi } = vi.hoisted(() => ({
  mockRoutesApi: {
    create: vi.fn(),
    update: vi.fn(),
    getById: vi.fn(),
    testSource: vi.fn(),
    switchSource: vi.fn(),
  },
  mockDestinationsApi: {
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
    getById: vi.fn(),
  },
  mockInterfacesApi: {
    getAll: vi.fn(),
    getSystemInterfaces: vi.fn(),
  },
  mockSourcesApi: {
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
    reorder: vi.fn(),
    test: vi.fn(),
  },
  mockTagsApi: {
    getAll: vi.fn(),
  },
}));

vi.mock('../../../utils/api', () => ({
  routesApi: mockRoutesApi,
  destinationsApi: mockDestinationsApi,
  interfacesApi: mockInterfacesApi,
  sourcesApi: mockSourcesApi,
  tagsApi: mockTagsApi,
}));

vi.mock('../../../utils/ndiApi', () => ({
  ndiApi: {
    getCapabilities: vi.fn(async () => ({
      data: {
        feature_enabled: false,
        plugin: { available: false, revision: null },
        runtime: { available: false, major: null, version: null },
        receive: { available: false, reason_codes: ['NDI_DISABLED'], formats: [] },
        send: { available: false, reason_codes: ['NDI_DISABLED'], formats: [] },
        discovery: { available: false, reason_codes: ['NDI_DISABLED'], mode: 'mdns' },
        direct_address: { available: false, reason_codes: ['NDI_DISABLED'] },
        checked_at: '2026-07-19T00:00:00Z',
        expires_at: '2026-07-19T00:00:15Z',
        stale: false,
        check_in_progress: false,
        node_id: 'self',
      },
    })),
    listSources: vi.fn(async () => ({ data: [], meta: {} })),
    refreshDiscovery: vi.fn(async () => ({ data: { generation: 'g1' } })),
    probe: vi.fn(async () => ({ data: { ok: false } })),
    getEndpointHealth: vi.fn(async () => ({ data: { endpoints: [], last_sequence: 0 } })),
  },
}));

const cloneSource = {
  id: 's1',
  route_id: 'r1',
  position: 0,
  status: 'started',
  name: 'Primary',
  schema: 'SRT',
  mode: 'listener',
  localport: 4201,
  enabled: true,
};

const cloneDestination = {
  id: 'd1',
  route_id: 'r1',
  position: 0,
  status: 'started',
  name: 'Dest 1',
  schema: 'UDP',
  mode: 'caller',
  host: '127.0.0.1',
  port: 5000,
  enabled: true,
};

const cloneRoute = {
  data: {
    id: 'r1',
    name: 'Route 1',
    enabled: true,
    status: 'started',
    active_source_id: 's1',
    node: 'self',
    gstDebug: '2',
    tags: ['live'],
    backup_mode: 'passive',
    sources: [cloneSource],
    destinations: [cloneDestination],
  },
};

const renderClonePage = () => {
  render(
    <MemoryRouter initialEntries={['/routes/new/edit?duplicate_from=r1']}>
      <Routes>
        <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
      </Routes>
    </MemoryRouter>,
  );
};

describe('Route clone prefill', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.setBreadcrumbItems = vi.fn();

    mockRoutesApi.getById.mockResolvedValue(cloneRoute);
    mockRoutesApi.create.mockResolvedValue({ data: { id: 'r2' } });
    mockSourcesApi.create.mockResolvedValue({ data: { id: 's2' } });
    mockDestinationsApi.create.mockResolvedValue({ data: { id: 'd2' } });
    mockSourcesApi.reorder.mockResolvedValue({});
    mockInterfacesApi.getAll.mockResolvedValue({ data: [] });
    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({ data: [] });
    mockTagsApi.getAll.mockResolvedValue({ data: [] });
  });

  it('pre-fills the new route form and shows clone warnings', async () => {
    renderClonePage();

    await waitFor(() => {
      expect(mockRoutesApi.getById).toHaveBeenCalledWith('r1');
      expect(screen.getByPlaceholderText('Enter route name')).toHaveValue('CLONE - Route 1');
      expect(screen.getByLabelText('Bind Port')).toHaveValue('4201');
    });

    expect(screen.getByText('Cloned from Route 1')).toBeInTheDocument();
    expect(screen.getByText('Source "Primary" binds a port the original route already holds.')).toBeInTheDocument();
  });

  it('saves the clone as new route and endpoints without updating the original', async () => {
    renderClonePage();

    await waitFor(() => {
      expect(screen.getByPlaceholderText('Enter route name')).toHaveValue('CLONE - Route 1');
    });
    fireEvent.change(screen.getByPlaceholderText('Enter bind address'), { target: { value: '0.0.0.0' } });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /save/i }));
    });

    await waitFor(() => {
      expect(mockRoutesApi.create).toHaveBeenCalledWith(expect.objectContaining({
        name: 'CLONE - Route 1',
        enabled: false,
      }));
    });
    expect(mockSourcesApi.create).toHaveBeenCalledTimes(1);
    expect(mockSourcesApi.create).toHaveBeenCalledWith('r2', expect.objectContaining({
      name: 'Primary',
      schema: 'SRT',
      mode: 'listener',
      localport: 4201,
    }));
    expect(mockDestinationsApi.create).toHaveBeenCalledTimes(1);
    expect(mockDestinationsApi.create).toHaveBeenCalledWith('r2', expect.objectContaining({
      name: 'Dest 1',
      schema: 'UDP',
      host: '127.0.0.1',
      port: 5000,
    }));
    expect(mockSourcesApi.create.mock.calls[0][1]).not.toHaveProperty('id');
    expect(mockSourcesApi.create.mock.calls[0][1]).not.toHaveProperty('route_id');
    expect(mockDestinationsApi.create.mock.calls[0][1]).not.toHaveProperty('id');
    expect(mockDestinationsApi.create.mock.calls[0][1]).not.toHaveProperty('route_id');
    expect(mockRoutesApi.update).not.toHaveBeenCalled();
    expect(mockSourcesApi.update).not.toHaveBeenCalled();
    expect(mockSourcesApi.delete).not.toHaveBeenCalled();
    expect(mockDestinationsApi.update).not.toHaveBeenCalled();
  });

  it('leaves a plain new route unaffected', () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(mockRoutesApi.getById).not.toHaveBeenCalled();
    expect(screen.queryByText(/Cloned from/)).not.toBeInTheDocument();
  });
});
