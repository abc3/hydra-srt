import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import InterfaceEdit from '../InterfaceEdit';

const { mockInterfacesApi } = vi.hoisted(() => ({
  mockInterfacesApi: {
    getById: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    getSystemInterfaces: vi.fn(),
  },
}));

vi.mock('../../../utils/api', () => ({
  interfacesApi: mockInterfacesApi,
}));

describe('Interface form validation', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.setBreadcrumbItems = vi.fn();

    mockInterfacesApi.getSystemInterfaces.mockResolvedValue({
      data: [{ sys_name: 'eno1', ip: '172.20.20.12/24' }],
    });
    mockInterfacesApi.create.mockResolvedValue({ data: { id: 'iface-1' } });
  });

  it('blocks save when required fields are empty', async () => {
    render(
      <MemoryRouter initialEntries={['/interfaces/new/edit']}>
        <Routes>
          <Route path="/interfaces/:id/edit" element={<InterfaceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    fireEvent.click(await screen.findByRole('button', { name: /save/i }));

    await waitFor(() => {
      expect(screen.getByText('Please enter an interface name')).toBeInTheDocument();
      expect(screen.getByText('Please select a system interface')).toBeInTheDocument();
      expect(screen.getByText('Please enter an interface IP')).toBeInTheDocument();
    });

    expect(mockInterfacesApi.create).not.toHaveBeenCalled();
  });

  it('submits manual sys_name when Other is selected', async () => {
    render(
      <MemoryRouter initialEntries={['/interfaces/new/edit']}>
        <Routes>
          <Route path="/interfaces/:id/edit" element={<InterfaceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    fireEvent.change(await screen.findByLabelText('Name'), { target: { value: 'MCAST-OUT' } });
    fireEvent.mouseDown(screen.getByLabelText('System Interface'));
    fireEvent.click(await screen.findByText('Other (enter manually)'));

    fireEvent.change(await screen.findByLabelText('System Name (manual)'), {
      target: { value: 'eno2' },
    });
    fireEvent.change(screen.getByLabelText('IP'), { target: { value: '192.168.221.15/24' } });

    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() => {
      expect(mockInterfacesApi.create).toHaveBeenCalledWith({
        name: 'MCAST-OUT',
        sys_name: 'eno2',
        ip: '192.168.221.15/24',
      });
    });
  });
});
