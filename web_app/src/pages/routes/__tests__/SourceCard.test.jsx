import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import RouteSourceEdit from '../RouteSourceEdit';

describe('SourceCard', () => {
  it('renders primary and backup source cards', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Source failover backup')).toBeInTheDocument();
    expect(screen.getByText('Primary Source')).toBeInTheDocument();
  });
});
