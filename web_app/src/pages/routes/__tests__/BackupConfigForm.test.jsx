import { describe, it, expect } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import RouteSourceEdit from '../RouteSourceEdit';

describe('BackupConfigForm', () => {
  it('shows active-only backup fields when mode=active', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Source failover backup')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('radio', { name: 'Active' }));
    expect(screen.getByText('Primary Stable (ms)')).toBeInTheDocument();
    expect(screen.getByText('Probe Interval (ms)')).toBeInTheDocument();
  });
});
