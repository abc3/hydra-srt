import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { Form, type FormInstance } from 'antd';
import { describe, expect, it, vi } from 'vitest';
import YoutubeInputFields from '../YoutubeInputFields';
import { youtubeApi } from '../../../utils/api';

vi.mock('../../../utils/api', () => ({
  youtubeApi: { inspect: vi.fn(), refresh: vi.fn() },
}));

// antd resolves the two path kinds differently: a Form.Item name is scoped by the enclosing
// Form.List, while useWatch and setFieldValue read from the form root. Getting one right and
// the other wrong breaks either saving or the Check button, so both are pinned here.
describe('YoutubeInputFields inside a Form.List', () => {
  let form: FormInstance;

  const renderInList = () => {
    const Wrapper = () => {
      const [formInstance] = Form.useForm();
      form = formInstance;
      return (
        <Form form={formInstance} initialValues={{ sources: [{ schema: 'YOUTUBE' }] }}>
          <Form.List name="sources">
            {(fields) => fields.map((field) => (
              <YoutubeInputFields
                key={field.key}
                namePrefix={[field.name]}
                valuePrefix={['sources', field.name]}
              />
            ))}
          </Form.List>
        </Form>
      );
    };
    return render(<Wrapper />);
  };

  const typeUrl = (value: string) =>
    fireEvent.change(screen.getByPlaceholderText('https://www.youtube.com/watch?v=...'), {
      target: { value },
    });

  it('writes the watch url into the source the form submits', () => {
    renderInList();
    typeUrl('https://www.youtube.com/watch?v=fO9e9jnhYK8');

    const values = form.getFieldsValue() as { sources?: Array<Record<string, unknown>> };
    expect(values.sources?.[0]?.youtube_url).toBe('https://www.youtube.com/watch?v=fO9e9jnhYK8');
    expect(values.sources?.[0]).not.toHaveProperty('sources');
  });

  it('keeps the quality policy on the same source entry', () => {
    renderInList();
    fireEvent.change(screen.getByPlaceholderText('best[height<=1080]'), {
      target: { value: 'best[height<=720]' },
    });

    const values = form.getFieldsValue() as { sources?: Array<Record<string, unknown>> };
    expect(values.sources?.[0]?.youtube_quality_policy).toBe('best[height<=720]');
  });

  it('sends the typed url when Check is pressed', async () => {
    vi.mocked(youtubeApi.inspect).mockResolvedValue({
      data: { live: true, variants: [], media_info: null },
    } as never);

    renderInList();
    typeUrl('https://www.youtube.com/watch?v=fO9e9jnhYK8');
    fireEvent.click(screen.getByRole('button', { name: /check/i }));

    await waitFor(() => {
      expect(youtubeApi.inspect).toHaveBeenCalledWith(
        'https://www.youtube.com/watch?v=fO9e9jnhYK8',
        'best[height<=1080]'
      );
    });
    expect(screen.queryByText('Enter a valid YouTube watch URL.')).toBeNull();
  });
});
