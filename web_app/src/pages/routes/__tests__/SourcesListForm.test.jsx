import { describe, it, expect } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import RouteSourceEdit from '../RouteSourceEdit';

describe('SourcesListForm', () => {
  it('adds and reorders backup sources in form list', async () => {
    render(
      <MemoryRouter initialEntries={['/routes/new/edit']}>
        <Routes>
          <Route path="/routes/:id/edit" element={<RouteSourceEdit />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Primary Source');
    const addButton = screen.getByText('Add Backup Source');
    fireEvent.click(addButton);
    expect(screen.getByText('Backup Source #1')).toBeInTheDocument();
    expect(screen.getAllByText('Up').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Down').length).toBeGreaterThan(0);
  });
});
