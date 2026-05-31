import { Form, Select, Switch } from 'antd';

type SrtAccessFieldsProps = {
  sourceName?: number;
};

const ipAccessEntryPattern =
  /^((\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]+)(\/\d{1,3})?$/;

const fieldName = (sourceName: number | undefined, key: string) =>
  sourceName === undefined ? key : [sourceName, key];

const fieldPath = (sourceName: number | undefined, key: string) =>
  sourceName === undefined ? key : ['sources', sourceName, key];

const validateEntries = async (_: unknown, entries?: string[]) => {
  const invalid = (entries || []).find((entry) => !ipAccessEntryPattern.test(String(entry).trim()));

  if (invalid) {
    throw new Error('Use IP addresses or CIDR ranges only');
  }
};

const SrtAccessFields = ({ sourceName }: SrtAccessFieldsProps) => (
  <Form.Item noStyle shouldUpdate>
    {({ getFieldValue }) => {
      const schema = getFieldValue(fieldPath(sourceName, 'schema'));
      const mode = getFieldValue(fieldPath(sourceName, 'mode'));

      if (schema !== 'SRT' || mode !== 'listener') {
        return null;
      }

      return (
        <>
          <Form.Item
            label="Limit Access"
            name={fieldName(sourceName, 'limit_access')}
            valuePropName="checked"
            extra="When disabled, saved allow/deny ranges are ignored and all callers can attempt to connect."
          >
            <Switch />
          </Form.Item>

          <Form.Item
            label="Allowed IPs"
            name={fieldName(sourceName, 'allowed_list')}
            extra="Optional allowlist. Enter IP addresses or CIDR ranges; leave empty to allow all except denied entries."
            rules={[{ validator: validateEntries }]}
          >
            <Select mode="tags" tokenSeparators={[',', '\n']} placeholder="127.0.0.1, 10.10.0.0/16" />
          </Form.Item>

          <Form.Item
            label="Denied IPs"
            name={fieldName(sourceName, 'denied_list')}
            extra="Optional denylist. Denied entries take priority over allowed entries."
            rules={[{ validator: validateEntries }]}
          >
            <Select mode="tags" tokenSeparators={[',', '\n']} placeholder="192.0.2.10" />
          </Form.Item>
        </>
      );
    }}
  </Form.Item>
);

export default SrtAccessFields;
