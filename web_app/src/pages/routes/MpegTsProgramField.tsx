import { AutoComplete, Form } from 'antd';
import type { SourceProgram } from '../../types/routes';

type Props = {
  sourceName?: number;
  programs?: SourceProgram[] | null;
};

const fieldName = (sourceName: number | undefined) =>
  sourceName === undefined ? 'program_number' : [sourceName, 'program_number'];

const fieldPath = (sourceName: number | undefined, key: string) =>
  sourceName === undefined ? key : ['sources', sourceName, key];

const parseProgramNumber = (value: string): number | string | null => {
  const trimmed = value.trim();
  if (trimmed === '') {
    return null;
  }

  return /^\d+$/.test(trimmed) ? Number(trimmed) : trimmed;
};

const validateProgramNumber = async (_rule: unknown, value: unknown) => {
  if (value === undefined || value === null || value === '') {
    return;
  }

  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error('Program number must be an integer between 1 and 65535');
  }
};

const MpegTsProgramField = ({ sourceName, programs }: Props) => (
  <Form.Item noStyle shouldUpdate>
    {({ getFieldValue }) => {
      const schema = getFieldValue(fieldPath(sourceName, 'schema'));
      if (schema !== 'UDP' && schema !== 'RTP' && schema !== 'SRT') {
        return null;
      }

      const selectedProgram = getFieldValue(fieldPath(sourceName, 'program_number')) as number | null | undefined;
      const programOptions = (programs ?? [])
        .filter((program) => Number.isInteger(program.program_number) && program.program_number >= 1 && program.program_number <= 65535)
        .map((program) => ({
          label: program.name ? `${program.program_number} - ${program.name}` : String(program.program_number),
          value: String(program.program_number),
        }));
      const values = new Set(programOptions.map((option) => option.value));

      if (selectedProgram != null && !values.has(String(selectedProgram))) {
        programOptions.push({ label: String(selectedProgram), value: String(selectedProgram) });
      }

      const options = [
        { label: 'All programs (passthrough)', value: '' },
        ...programOptions,
      ];

      return (
        <Form.Item
          label="Program Number (PNR)"
          name={fieldName(sourceName)}
          extra="The program to extract from a multi-program transport stream. Leave empty to forward every program."
          getValueProps={(value: number | null | undefined) => ({ value: value == null ? '' : String(value) })}
          getValueFromEvent={parseProgramNumber}
          rules={[{ validator: validateProgramNumber }]}
        >
          <AutoComplete
            allowClear
            options={options}
            filterOption={(inputValue, option) => String(option?.label ?? '').toLowerCase().includes(inputValue.toLowerCase())}
            placeholder="All programs (passthrough)"
          />
        </Form.Item>
      );
    }}
  </Form.Item>
);

export default MpegTsProgramField;
