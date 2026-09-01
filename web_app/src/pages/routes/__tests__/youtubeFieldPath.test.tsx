import { fireEvent, render, screen } from '@testing-library/react';
import { Form, type FormInstance } from 'antd';
import { describe, expect, it, vi } from 'vitest';
import YoutubeInputFields from '../YoutubeInputFields';

vi.mock('../../../utils/api', () => ({
  youtubeApi: { inspect: vi.fn(), refresh: vi.fn() },
}));

// Inside a Form.List the list already scopes its children, so a prefix that repeats the
// list name writes the value one level too deep and it never reaches the submitted source.
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
              <YoutubeInputFields key={field.key} namePrefix={[field.name]} />
            ))}
          </Form.List>
        </Form>
      );
    };
    return render(<Wrapper />);
  };

  it('writes the watch url into the source the form submits', () => {
    renderInList();

    fireEvent.change(screen.getByPlaceholderText('https://www.youtube.com/watch?v=...'), {
      target: { value: 'https://www.youtube.com/watch?v=fO9e9jnhYK8' },
    });

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
});
