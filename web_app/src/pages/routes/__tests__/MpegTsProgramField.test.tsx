import { describe, expect, it } from 'vitest';
import { Form } from 'antd';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import MpegTsProgramField from '../MpegTsProgramField';

const programs = [
  {
    program_number: 12,
    pmt_pid: 4097,
    pcr_pid: 258,
    name: 'Sport HD',
    streams: [{ codec_type: 'video', codec_name: 'h264' }],
  },
  {
    program_number: 13,
    pmt_pid: 4098,
    pcr_pid: 259,
    name: null,
    streams: [{ codec_type: 'audio', codec_name: 'aac' }],
  },
];

describe('MpegTsProgramField', () => {
  it.each(['UDP', 'RTP', 'SRT'])('renders for %s sources', (schema) => {
    render(
      <Form initialValues={{ schema }}>
        <Form.Item name="schema"><input /></Form.Item>
        <MpegTsProgramField programs={programs} />
      </Form>,
    );

    expect(screen.getByText('Program Number (PNR)')).toBeInTheDocument();
  });

  it.each(['RTMP', 'NDI'])('does not render for %s sources', (schema) => {
    render(
      <Form initialValues={{ schema }}>
        <Form.Item name="schema"><input /></Form.Item>
        <MpegTsProgramField programs={programs} />
      </Form>,
    );

    expect(screen.queryByText('Program Number (PNR)')).not.toBeInTheDocument();
  });

  it('shows probed programs and preserves an unlisted saved value', async () => {
    render(
      <Form initialValues={{ schema: 'UDP', program_number: 99 }}>
        <Form.Item name="schema"><input /></Form.Item>
        <MpegTsProgramField programs={programs} />
      </Form>,
    );

    const input = screen.getByRole('combobox');
    expect(input).toHaveValue('99');
    fireEvent.change(input, { target: { value: '' } });
    fireEvent.mouseDown(screen.getByRole('combobox'));

    expect(await screen.findByText('12 - Sport HD')).toBeInTheDocument();
    expect(screen.getByText('13')).toBeInTheDocument();
    expect(screen.getAllByText('All programs (passthrough)').length).toBeGreaterThan(1);
  });

  it.each([
    ['a non-numeric entry', 'abc'],
    ['a decimal entry', '12.5'],
    ['zero', '0'],
  ])('rejects %s', async (_label, entered) => {
    let failed = false;
    render(
      <Form
        initialValues={{ schema: 'UDP' }}
        onFinishFailed={() => {
          failed = true;
        }}
      >
        <Form.Item name="schema"><input /></Form.Item>
        <MpegTsProgramField />
        <button type="submit">Save</button>
      </Form>,
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: entered } });
    fireEvent.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => {
      expect(failed).toBe(true);
    });
  });

  it('accepts an empty value as passthrough', async () => {
    let submitted: Record<string, unknown> | null = null;
    render(
      <Form
        initialValues={{ schema: 'UDP', program_number: 12 }}
        onFinish={(values) => {
          submitted = values;
        }}
      >
        <Form.Item name="schema"><input /></Form.Item>
        <MpegTsProgramField />
        <button type="submit">Save</button>
      </Form>,
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => {
      expect(submitted).not.toBeNull();
    });
    expect(submitted!.program_number).toBeNull();
  });

  it('rejects values outside the MPEG-TS program range', async () => {
    let failed = false;
    render(
      <Form
        initialValues={{ schema: 'UDP' }}
        onFinishFailed={() => {
          failed = true;
        }}
      >
        <Form.Item name="schema"><input /></Form.Item>
        <MpegTsProgramField />
        <button type="submit">Save</button>
      </Form>,
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: '65536' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => {
      expect(failed).toBe(true);
    });
  });
});
