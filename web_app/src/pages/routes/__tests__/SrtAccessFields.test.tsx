import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { Form } from 'antd';
import { describe, expect, it } from 'vitest';
import SrtAccessFields from '../SrtAccessFields';

const renderListenerAccessFields = (initialValues: Record<string, unknown> = {}) => {
  const Wrapper = () => (
    <Form
      initialValues={{
        schema: 'SRT',
        mode: 'listener',
        limit_access: false,
        allowed_list: [],
        denied_list: [],
        ...initialValues,
      }}
    >
      <SrtAccessFields />
    </Form>
  );

  return render(<Wrapper />);
};

const renderIndexedListenerAccessFields = (sourceValues: Record<string, unknown>) => {
  const Wrapper = () => (
    <Form
      initialValues={{
        sources: [{
          schema: 'SRT',
          mode: 'listener',
          limit_access: false,
          allowed_list: [],
          denied_list: [],
          ...sourceValues,
        }],
      }}
    >
      <SrtAccessFields sourceName={0} />
    </Form>
  );

  return render(<Wrapper />);
};

describe('SrtAccessFields', () => {
  it('applies the allowlist only preset', async () => {
    renderListenerAccessFields();

    fireEvent.mouseDown(screen.getByRole('combobox', { name: 'Security preset' }));
    fireEvent.click(await screen.findByText('Allowlist only'));

    await waitFor(() => {
      expect(screen.getByRole('switch', { name: 'Limit Access' })).toBeChecked();
    });
  });

  it('shows no preset selection for a custom allow and deny combination', () => {
    renderListenerAccessFields({
      limit_access: true,
      allowed_list: ['10.0.0.0/8'],
      denied_list: ['203.0.113.5'],
    });

    expect(screen.getByText('Custom configuration')).toBeInTheDocument();
  });

  it('disables stream ID match while expected stream ID is empty', () => {
    renderListenerAccessFields();

    const matchSelect = screen.getByRole('combobox', { name: 'Stream ID match' });
    expect(matchSelect).toBeDisabled();

    fireEvent.change(screen.getByRole('textbox', { name: 'Expected Stream ID' }), {
      target: { value: 'studio-a' },
    });

    expect(screen.getByRole('combobox', { name: 'Stream ID match' })).not.toBeDisabled();
  });

  it('fills listener fields from the stream ID required preset in a sources list', async () => {
    renderIndexedListenerAccessFields({ allowed_list: ['10.0.0.0/8'] });

    fireEvent.mouseDown(screen.getByRole('combobox', { name: 'Security preset' }));
    fireEvent.click(await screen.findByText('Stream ID required'));

    await waitFor(() => {
      expect(screen.getByRole('switch', { name: 'Limit Access' })).not.toBeChecked();
      expect(screen.getByRole('textbox', { name: 'Expected Stream ID' })).toHaveValue('');
      expect(screen.getByRole('combobox', { name: 'Allowed IPs' })).toHaveTextContent('');
    });
  });
});
