import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, act, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteSourceEdit from '../RouteSourceEdit';
import RouteDestEdit from '../RouteDestEdit';

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

vi.mock('../../../utils/api', () => {
  return {
    routesApi: mockRoutesApi,
    destinationsApi: mockDestinationsApi,
    interfacesApi: mockInterfacesApi,
    sourcesApi: mockSourcesApi,
    tagsApi: mockTagsApi,
  };
});

describe('Route form validation', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.setBreadcrumbItems = vi.fn();

    mockRoutesApi.getById.mockResolvedValue({
      data: {
        id: 'r1',
        name: 'Route 1',
      },
    });
    mockInterfacesApi.getAll.mockResolvedValue({ data: [] });
    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({ data: [] });
    mockTagsApi.getAll.mockResolvedValue({ data: [] });
  });

  it('blocks source save when required fields are empty', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /save/i }));
    });

    await waitFor(() => {
      expect(screen.getByText('Please enter a route name')).toBeInTheDocument();
      expect(screen.getByText('Please enter a bind port')).toBeInTheDocument();
    });

    expect(mockRoutesApi.create).not.toHaveBeenCalled();
  });

  it('blocks destination save when required fields are empty', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/r1/destinations/new']}>
        <Routes>
          <Route path="/routes/:routeId/destinations/:destId" element={<RouteDestEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    await waitFor(() => {
      expect(mockRoutesApi.getById).toHaveBeenCalledWith('r1');
    });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /save/i }));
    });

    await waitFor(() => {
      expect(screen.getByText('Please enter a destination name')).toBeInTheDocument();
      expect(screen.getByText('Please select an SRT mode')).toBeInTheDocument();
    });

    expect(mockDestinationsApi.create).not.toHaveBeenCalled();
  });

  it('requires source ports for SRT source', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    fireEvent.change(screen.getByPlaceholderText('Enter route name'), { target: { value: 'Route 1' } });
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /save/i }));
    });

    await waitFor(() => {
      expect(screen.getByText('Please enter a bind port')).toBeInTheDocument();
    });

    expect(mockRoutesApi.create).not.toHaveBeenCalled();
  });

  it('shows SRT source IP access controls only for listener mode', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    const sourceTitle = await screen.findByText('Primary Source');
    const sourceCard = sourceTitle.closest('.ant-card');
    expect(sourceCard).not.toBeNull();
    if (!(sourceCard instanceof HTMLElement)) {
      throw new Error('Source card was not found');
    }

    const sourceScope = within(sourceCard);
    expect(sourceScope.getByText('Limit Access')).toBeInTheDocument();
    expect(sourceScope.getByText('Allowed IPs')).toBeInTheDocument();
    expect(sourceScope.getByText('Denied IPs')).toBeInTheDocument();
    expect(sourceScope.queryByPlaceholderText('Enter Stream ID')).not.toBeInTheDocument();

    fireEvent.click(sourceScope.getByRole('radio', { name: 'Caller' }));

    await waitFor(() => {
      expect(sourceScope.queryByText('Limit Access')).not.toBeInTheDocument();
      expect(sourceScope.getByPlaceholderText('Enter Stream ID')).toBeInTheDocument();
    });

    fireEvent.change(sourceScope.getByPlaceholderText('Enter Stream ID'), {
      target: { value: '#!::r=channel' },
    });
    fireEvent.click(sourceScope.getByRole('radio', { name: 'Listener' }));
    expect(sourceScope.queryByPlaceholderText('Enter Stream ID')).not.toBeInTheDocument();
    fireEvent.click(sourceScope.getByRole('radio', { name: 'Caller' }));
    expect(sourceScope.getByPlaceholderText('Enter Stream ID')).toHaveValue('#!::r=channel');
  });

  it('shows destination SRT authentication fields on new route form', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    const destinationTitle = await screen.findByText('Destination #1');
    const destinationCard = destinationTitle.closest('.ant-card');
    expect(destinationCard).not.toBeNull();
    if (!(destinationCard instanceof HTMLElement)) {
      throw new Error('Destination card was not found');
    }

    const destinationScope = within(destinationCard);

    expect(destinationScope.queryByText('Authentication')).not.toBeInTheDocument();

    fireEvent.click(destinationScope.getByRole('radio', { name: 'SRT' }));

    await waitFor(() => {
      expect(destinationScope.getByText('Authentication')).toBeInTheDocument();
      expect(destinationScope.getByPlaceholderText('Enter Stream ID')).toBeInTheDocument();
    });

    const switches = destinationScope.getAllByRole('switch');
    fireEvent.click(switches[switches.length - 1]);

    await waitFor(() => {
      expect(destinationScope.getByPlaceholderText('Enter passphrase')).toBeInTheDocument();
      expect(destinationScope.getByText('Key Length')).toBeInTheDocument();
    });
  });

  it('loads interface options from system interfaces when database is empty', async () => {
    mockInterfacesApi.getAll.mockResolvedValue({ data: [] });
    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({
      data: [{ sys_name: 'eth0', ip: '10.10.10.1/24' }],
    });

    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    const sourceTitle = await screen.findByText('Primary Source');
    const sourceCard = sourceTitle.closest('.ant-card');
    expect(sourceCard).not.toBeNull();
    if (!(sourceCard instanceof HTMLElement)) {
      throw new Error('Source card was not found');
    }

    fireEvent.mouseDown(within(sourceCard).getByLabelText('Interface'));

    expect(await screen.findByText('eth0 (eth0 - 10.10.10.1/24)')).toBeInTheDocument();
  });

  it('saves UDP multicast source settings from the route form', async () => {
    mockInterfacesApi.getAll.mockResolvedValue({ data: [] });
    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({
      data: [{ sys_name: 'eth0', ip: '10.10.10.1/24' }],
    });
    mockRoutesApi.create.mockResolvedValue({ data: { id: 'route-1' } });
    mockSourcesApi.create.mockResolvedValue({ data: { id: 'source-1' } });
    mockDestinationsApi.create.mockResolvedValue({ data: { id: 'dest-1' } });
    mockSourcesApi.reorder.mockResolvedValue({ data: [] });

    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    fireEvent.change(screen.getByPlaceholderText('Enter route name'), { target: { value: 'Route 1' } });

    const sourceTitle = await screen.findByText('Primary Source');
    const sourceCard = sourceTitle.closest('.ant-card');
    expect(sourceCard).not.toBeNull();
    if (!(sourceCard instanceof HTMLElement)) {
      throw new Error('Source card was not found');
    }
    const sourceScope = within(sourceCard);

    fireEvent.click(sourceScope.getByRole('radio', { name: 'UDP' }));
    fireEvent.click(await sourceScope.findByLabelText('Multicast source'));
    fireEvent.change(sourceScope.getByPlaceholderText('239.1.1.1'), { target: { value: '239.1.1.1' } });
    fireEvent.change(sourceScope.getByLabelText('Port'), { target: { value: '5000' } });
    fireEvent.mouseDown(sourceScope.getByLabelText('Interface'));
    fireEvent.click(await screen.findByText('eth0 (eth0 - 10.10.10.1/24)'));

    const destinationTitle = await screen.findByText('Destination #1');
    const destinationCard = destinationTitle.closest('.ant-card');
    expect(destinationCard).not.toBeNull();
    if (!(destinationCard instanceof HTMLElement)) {
      throw new Error('Destination card was not found');
    }
    const destinationScope = within(destinationCard);
    fireEvent.change(destinationScope.getByLabelText('Port'), { target: { value: '6000' } });

    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /save/i }));
    });

    await waitFor(() => {
      expect(mockSourcesApi.create).toHaveBeenCalled();
    });

    expect(mockSourcesApi.create).toHaveBeenCalledWith(
      'route-1',
      expect.objectContaining({
        schema: 'UDP',
        address: '239.1.1.1',
        port: 5000,
        multicast: true,
        interface_sys_name: 'eth0',
      }),
    );
  });
});
