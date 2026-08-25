import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, act, within } from '@testing-library/react';
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

const PRIMARY_SOURCE_ID = '279f1d52-803c-44f2-9e7e-5f3b0c7cc9c4';
const SECOND_SOURCE_ID = '8e1c4a01-11d2-4e4d-9d0b-1a9f1c0a7b31';
const DESTINATION_ID = '4a4942ef-ec21-4370-8767-132642202286';

const primarySource = {
  id: PRIMARY_SOURCE_ID,
  name: 'Primary',
  schema: 'SRT',
  mode: 'caller',
  enabled: true,
  position: 0,
  address: '10.0.0.1',
  port: 9500,
  auto_reconnect: true,
  keep_listening: true,
};

const secondSource = {
  ...primarySource,
  id: SECOND_SOURCE_ID,
  name: 'Backup 1',
  position: 1,
  port: 9501,
};

const destination = {
  id: DESTINATION_ID,
  name: 'Destination 1',
  schema: 'SRT',
  mode: 'listener',
  enabled: true,
  position: 0,
  localaddress: '0.0.0.0',
  localport: 8500,
  latency: 1000,
};

const routeFixture = (sources: unknown[]) => ({
  data: {
    id: 'r1',
    name: 'playtv backup',
    enabled: true,
    node: 'self',
    gstDebug: '2',
    backup_mode: 'active',
    active_source_id: PRIMARY_SOURCE_ID,
    sources,
    destinations: [destination],
    tags: [],
  },
});

const renderEditPage = async () => {
  render(
    <MemoryRouter initialEntries={['/routes/r1/edit']}>
      <Routes>
        <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
      </Routes>
    </MemoryRouter>,
  );

  await waitFor(() => {
    expect(mockRoutesApi.getById).toHaveBeenCalledWith('r1');
  });
  await screen.findByText('Primary Source');
};

const save = async () => {
  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: /save/i }));
  });
};

const cardScope = (title: string) => {
  const card = screen.getByText(title).closest('.ant-card');
  if (!(card instanceof HTMLElement)) {
    throw new Error(`Card "${title}" was not found`);
  }
  return within(card);
};

describe('Edit Route persists sources and destinations', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.setBreadcrumbItems = vi.fn();

    mockRoutesApi.getById.mockResolvedValue(routeFixture([primarySource]));
    mockRoutesApi.update.mockResolvedValue({ data: { id: 'r1' } });
    mockSourcesApi.create.mockResolvedValue({ data: { id: 'new-source-id' } });
    mockSourcesApi.update.mockResolvedValue({ data: { id: PRIMARY_SOURCE_ID } });
    mockSourcesApi.delete.mockResolvedValue({});
    mockSourcesApi.reorder.mockResolvedValue({ data: [] });
    mockDestinationsApi.update.mockResolvedValue({ data: { id: DESTINATION_ID } });
    mockInterfacesApi.getAll.mockResolvedValue({ data: [] });
    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({ data: [] });
    mockTagsApi.getAll.mockResolvedValue({ data: [] });
  });

  it('creates a backup source added to an existing route', async () => {
    await renderEditPage();

    fireEvent.click(screen.getByRole('button', { name: /add backup source/i }));

    const backupScope = cardScope('Backup Source #1');
    fireEvent.click(backupScope.getByRole('radio', { name: 'Caller' }));
    await waitFor(() => {
      expect(backupScope.getByPlaceholderText('Enter remote address')).toBeInTheDocument();
    });
    fireEvent.change(backupScope.getByPlaceholderText('Enter remote address'), { target: { value: '10.0.0.2' } });
    fireEvent.change(backupScope.getByLabelText('Remote Port'), { target: { value: '9600' } });

    await save();

    await waitFor(() => {
      expect(mockSourcesApi.create).toHaveBeenCalledTimes(1);
    });

    const [routeId, payload] = mockSourcesApi.create.mock.calls[0];
    expect(routeId).toBe('r1');
    expect(payload).toMatchObject({
      name: 'Backup 1',
      schema: 'SRT',
      mode: 'caller',
      address: '10.0.0.2',
      port: 9600,
    });

    // The existing source is updated rather than duplicated, and ordering is settled
    // by the reorder call.
    expect(mockSourcesApi.update).toHaveBeenCalledTimes(1);
    expect(mockSourcesApi.update.mock.calls[0][1]).toBe(PRIMARY_SOURCE_ID);
    expect(mockSourcesApi.reorder).toHaveBeenCalledWith('r1', [PRIMARY_SOURCE_ID, 'new-source-id']);
    expect(mockSourcesApi.delete).not.toHaveBeenCalled();
  });

  it('deletes a source removed from an existing route', async () => {
    mockRoutesApi.getById.mockResolvedValue(routeFixture([primarySource, secondSource]));

    await renderEditPage();

    fireEvent.click(cardScope('Backup Source #1').getByRole('button', { name: /delete/i }));

    await save();

    await waitFor(() => {
      expect(mockSourcesApi.delete).toHaveBeenCalledWith('r1', SECOND_SOURCE_ID);
    });
    expect(mockSourcesApi.create).not.toHaveBeenCalled();
    expect(mockSourcesApi.reorder).toHaveBeenCalledWith('r1', [PRIMARY_SOURCE_ID]);
  });

  it('hands off the active slot before deleting the active source', async () => {
    // active_source_id points at the primary, and the primary is the one being removed.
    mockRoutesApi.getById.mockResolvedValue(routeFixture([primarySource, secondSource]));
    mockRoutesApi.switchSource.mockResolvedValue({ data: {} });

    const callOrder: string[] = [];
    mockRoutesApi.switchSource.mockImplementation(async () => { callOrder.push('switch'); return { data: {} }; });
    mockSourcesApi.delete.mockImplementation(async () => { callOrder.push('delete'); return {}; });

    await renderEditPage();

    fireEvent.click(cardScope('Primary Source').getByRole('button', { name: /delete/i }));

    await save();

    await waitFor(() => {
      expect(mockSourcesApi.delete).toHaveBeenCalledWith('r1', PRIMARY_SOURCE_ID);
    });

    // The backend rejects deleting a route's active source, so the switch must land first.
    expect(mockRoutesApi.switchSource).toHaveBeenCalledWith('r1', SECOND_SOURCE_ID);
    expect(callOrder).toEqual(['switch', 'delete']);
  });

  it('does not switch the active source when it survives the save', async () => {
    mockRoutesApi.getById.mockResolvedValue(routeFixture([primarySource, secondSource]));

    await renderEditPage();

    fireEvent.click(cardScope('Backup Source #1').getByRole('button', { name: /delete/i }));

    await save();

    await waitFor(() => {
      expect(mockSourcesApi.delete).toHaveBeenCalledWith('r1', SECOND_SOURCE_ID);
    });
    expect(mockRoutesApi.switchSource).not.toHaveBeenCalled();
  });

  it('does not write colliding positions when sources are reordered', async () => {
    mockRoutesApi.getById.mockResolvedValue(routeFixture([primarySource, secondSource]));

    await renderEditPage();

    fireEvent.click(cardScope('Backup Source #1').getByRole('button', { name: 'Up' }));

    await save();

    await waitFor(() => {
      expect(mockSourcesApi.reorder).toHaveBeenCalledWith('r1', [SECOND_SOURCE_ID, PRIMARY_SOURCE_ID]);
    });

    // Writing final positions in the per-source PATCH would trip the
    // (route_id, position, type) unique index on a swap.
    for (const [, , payload] of mockSourcesApi.update.mock.calls) {
      expect(payload).not.toHaveProperty('position');
    }
  });

  it('updates existing destinations instead of dropping the edit', async () => {
    await renderEditPage();

    const destinationScope = cardScope('Destination #1');
    fireEvent.change(destinationScope.getByPlaceholderText('Destination name'), {
      target: { value: 'Renamed destination' },
    });

    await save();

    await waitFor(() => {
      expect(mockDestinationsApi.update).toHaveBeenCalledTimes(1);
    });
    const [routeId, destId, payload] = mockDestinationsApi.update.mock.calls[0];
    expect(routeId).toBe('r1');
    expect(destId).toBe(DESTINATION_ID);
    expect(payload).toMatchObject({ name: 'Renamed destination' });
    expect(mockDestinationsApi.create).not.toHaveBeenCalled();
  });

  it('still updates the route row itself', async () => {
    await renderEditPage();

    fireEvent.change(screen.getByPlaceholderText('Enter route name'), { target: { value: 'Renamed route' } });

    await save();

    await waitFor(() => {
      expect(mockRoutesApi.update).toHaveBeenCalledTimes(1);
    });
    expect(mockRoutesApi.update.mock.calls[0][1]).toMatchObject({
      name: 'Renamed route',
      backup_mode: 'active',
    });
    expect(mockRoutesApi.create).not.toHaveBeenCalled();
  });
});
