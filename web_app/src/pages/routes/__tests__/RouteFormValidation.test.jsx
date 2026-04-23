import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import RouteSourceEdit from '../RouteSourceEdit';
import RouteDestEdit from '../RouteDestEdit';

const { mockRoutesApi, mockDestinationsApi } = vi.hoisted(() => ({
  mockRoutesApi: {
    create: vi.fn(),
    update: vi.fn(),
    getById: vi.fn(),
    testSource: vi.fn(),
  },
  mockDestinationsApi: {
    create: vi.fn(),
    update: vi.fn(),
    getById: vi.fn(),
  },
}));

vi.mock('../../../utils/api', () => {
  return {
    routesApi: mockRoutesApi,
    destinationsApi: mockDestinationsApi,
  };
});

describe('Route form validation', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.setBreadcrumbItems = vi.fn();
    window.breadcrumbSet = false;

    mockRoutesApi.getById.mockResolvedValue({
      data: {
        id: 'r1',
        name: 'Route 1',
      },
    });
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
      expect(screen.getByText('Please enter a local port')).toBeInTheDocument();
    });

    expect(mockDestinationsApi.create).not.toHaveBeenCalled();
  });
});
