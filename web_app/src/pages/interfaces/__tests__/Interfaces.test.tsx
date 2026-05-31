import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Interfaces from '../Interfaces';

const { mockInterfacesApi } = vi.hoisted(() => ({
  mockInterfacesApi: {
    getAll: vi.fn(),
    getSystemInterfaces: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
  },
}));

vi.mock('../../../utils/api', () => ({
  interfacesApi: mockInterfacesApi,
}));

describe('Interfaces page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockInterfacesApi.getAll.mockResolvedValue({
      data: [
        {
          id: 'iface-1',
          name: 'ISP-1',
          sys_name: 'eno1',
          ip: '172.20.20.12/24',
        },
      ],
    });
    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({
      data: [
        {
          sys_name: 'eno1',
          ip: '172.20.20.12/24',
          multicast_supported: true,
        },
      ],
    });
    mockInterfacesApi.update.mockResolvedValue({ data: { id: 'iface-1' } });
    mockInterfacesApi.create.mockResolvedValue({ data: { id: 'iface-2' } });
  });

  it('renders interfaces from API', async () => {
    render(
      <MemoryRouter>
        <Interfaces />
      </MemoryRouter>,
    );

    expect(await screen.findByText('ISP-1')).toBeInTheDocument();
    expect(screen.getByText('eno1')).toBeInTheDocument();
    expect(screen.getByText('172.20.20.12/24')).toBeInTheDocument();
  });

  it('renders discovered system interface even without saved alias', async () => {
    mockInterfacesApi.getAll.mockResolvedValue({ data: [] });
    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({
      data: [
        {
          sys_name: 'en9',
          ip: '10.10.10.10/24',
          multicast_supported: false,
        },
      ],
    });

    render(
      <MemoryRouter>
        <Interfaces />
      </MemoryRouter>,
    );

    expect(await screen.findByText('en9')).toBeInTheDocument();
    expect(screen.getByText('10.10.10.10/24')).toBeInTheDocument();
    expect(screen.getByText('Click to set')).toBeInTheDocument();
  });

  it('updates alias name on single click edit', async () => {
    render(
      <MemoryRouter>
        <Interfaces />
      </MemoryRouter>,
    );

    const nameCell = await screen.findByText('ISP-1');
    fireEvent.click(nameCell);

    const input = await screen.findByDisplayValue('ISP-1');
    fireEvent.change(input, { target: { value: 'ISP-ONE' } });
    fireEvent.keyDown(input, { key: 'Enter', code: 'Enter' });

    await waitFor(() => {
      expect(mockInterfacesApi.update).toHaveBeenCalledWith('iface-1', {
        name: 'ISP-ONE',
        sys_name: 'eno1',
        ip: '172.20.20.12/24',
        enabled: true,
      });
    });
  });

  it('does not save empty value when clicking away', async () => {
    render(
      <MemoryRouter>
        <Interfaces />
      </MemoryRouter>,
    );

    const nameCell = await screen.findByText('ISP-1');
    fireEvent.click(nameCell);

    const input = await screen.findByDisplayValue('ISP-1');
    fireEvent.change(input, { target: { value: '   ' } });
    fireEvent.blur(input);

    await waitFor(() => {
      expect(screen.getByText('ISP-1')).toBeInTheDocument();
    });

    expect(mockInterfacesApi.update).not.toHaveBeenCalled();
    expect(mockInterfacesApi.create).not.toHaveBeenCalled();
  });
});
