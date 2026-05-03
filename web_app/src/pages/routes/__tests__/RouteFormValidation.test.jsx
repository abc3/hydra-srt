import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, act, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteSourceEdit from '../RouteSourceEdit';
import RouteDestEdit from '../RouteDestEdit';

const { mockRoutesApi, mockDestinationsApi, mockInterfacesApi, mockSourcesApi } = vi.hoisted(() => ({
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
  },
  mockSourcesApi: {
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
    reorder: vi.fn(),
    test: vi.fn(),
  },
}));

vi.mock('../../../utils/api', () => {
  return {
    routesApi: mockRoutesApi,
    destinationsApi: mockDestinationsApi,
    interfacesApi: mockInterfacesApi,
    sourcesApi: mockSourcesApi,
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

    const destinationScope = within(destinationCard);

    expect(destinationScope.queryByText('Authentication')).not.toBeInTheDocument();

    fireEvent.click(destinationScope.getByRole('radio', { name: 'SRT' }));

    await waitFor(() => {
      expect(destinationScope.getByText('Authentication')).toBeInTheDocument();
    });

    const switches = destinationScope.getAllByRole('switch');
    fireEvent.click(switches[switches.length - 1]);

    await waitFor(() => {
      expect(destinationScope.getByPlaceholderText('Enter passphrase')).toBeInTheDocument();
      expect(destinationScope.getByText('Key Length')).toBeInTheDocument();
    });
  });
});
