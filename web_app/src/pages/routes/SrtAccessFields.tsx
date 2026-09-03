import { Form, Input, InputNumber, Select, Switch } from 'antd';
import type { FormInstance } from 'antd';

type SrtAccessFieldsProps = {
  sourceName?: number;
};

import { ipAccessEntryPattern } from './srtAccessPatterns';

const SECURITY_PRESET_ALLOW_ALL = 'allow_all';
const SECURITY_PRESET_ALLOWLIST = 'allowlist_only';
const SECURITY_PRESET_STREAMID = 'streamid_required';
const SECURITY_PRESET_ALLOWLIST_STREAMID = 'allowlist_streamid';

type SecurityPresetId =
  | typeof SECURITY_PRESET_ALLOW_ALL
  | typeof SECURITY_PRESET_ALLOWLIST
  | typeof SECURITY_PRESET_STREAMID
  | typeof SECURITY_PRESET_ALLOWLIST_STREAMID;

const SECURITY_PRESET_OPTIONS: Array<{ label: string; value: SecurityPresetId }> = [
  { label: 'Allow all callers', value: SECURITY_PRESET_ALLOW_ALL },
  { label: 'Allowlist only', value: SECURITY_PRESET_ALLOWLIST },
  { label: 'Stream ID required', value: SECURITY_PRESET_STREAMID },
  { label: 'Allowlist + Stream ID', value: SECURITY_PRESET_ALLOWLIST_STREAMID },
];

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

const isEmptyList = (entries: unknown): boolean => {
  if (!Array.isArray(entries) || entries.length === 0) {
    return true;
  }
  return entries.every((entry) => String(entry).trim() === '');
};

const isEmptyString = (value: unknown): boolean =>
  value === undefined || value === null || String(value).trim() === '';

const isEmptyMaxCallers = (value: unknown): boolean =>
  value === undefined || value === null || value === '';

const readAccessFields = (
  getFieldValue: FormInstance['getFieldValue'],
  sourceName: number | undefined,
) => ({
  limit_access: Boolean(getFieldValue(fieldPath(sourceName, 'limit_access'))),
  streamid: getFieldValue(fieldPath(sourceName, 'streamid')),
  streamid_match_mode: getFieldValue(fieldPath(sourceName, 'streamid_match_mode')),
  max_callers: getFieldValue(fieldPath(sourceName, 'max_callers')),
  allowed_list: getFieldValue(fieldPath(sourceName, 'allowed_list')),
  denied_list: getFieldValue(fieldPath(sourceName, 'denied_list')),
});

const detectSecurityPreset = (
  getFieldValue: FormInstance['getFieldValue'],
  sourceName: number | undefined,
): SecurityPresetId | undefined => {
  const fields = readAccessFields(getFieldValue, sourceName);
  const noStreamid = isEmptyString(fields.streamid);
  const noMaxCallers = isEmptyMaxCallers(fields.max_callers);
  const noAllowed = isEmptyList(fields.allowed_list);
  const noDenied = isEmptyList(fields.denied_list);

  if (
    !fields.limit_access &&
    noStreamid &&
    noMaxCallers &&
    noAllowed &&
    noDenied
  ) {
    return SECURITY_PRESET_ALLOW_ALL;
  }

  if (
    fields.limit_access &&
    noStreamid &&
    noMaxCallers &&
    !noAllowed &&
    noDenied
  ) {
    return SECURITY_PRESET_ALLOWLIST;
  }

  if (
    !fields.limit_access &&
    !noStreamid &&
    noMaxCallers &&
    noAllowed &&
    noDenied
  ) {
    return SECURITY_PRESET_STREAMID;
  }

  if (
    fields.limit_access &&
    !noStreamid &&
    noMaxCallers &&
    !noAllowed &&
    noDenied
  ) {
    return SECURITY_PRESET_ALLOWLIST_STREAMID;
  }

  return undefined;
};

const setAccessField = (
  form: FormInstance,
  sourceName: number | undefined,
  key: string,
  value: unknown,
) => {
  form.setFieldValue(fieldPath(sourceName, key), value);
};

const applySecurityPreset = (
  form: FormInstance,
  sourceName: number | undefined,
  preset: SecurityPresetId,
) => {
  switch (preset) {
    case SECURITY_PRESET_ALLOW_ALL:
      setAccessField(form, sourceName, 'limit_access', false);
      setAccessField(form, sourceName, 'allowed_list', []);
      setAccessField(form, sourceName, 'denied_list', []);
      setAccessField(form, sourceName, 'streamid', undefined);
      setAccessField(form, sourceName, 'streamid_match_mode', undefined);
      setAccessField(form, sourceName, 'max_callers', undefined);
      break;
    case SECURITY_PRESET_ALLOWLIST:
      setAccessField(form, sourceName, 'limit_access', true);
      setAccessField(form, sourceName, 'denied_list', []);
      setAccessField(form, sourceName, 'streamid', undefined);
      setAccessField(form, sourceName, 'streamid_match_mode', undefined);
      setAccessField(form, sourceName, 'max_callers', undefined);
      break;
    case SECURITY_PRESET_STREAMID:
      setAccessField(form, sourceName, 'limit_access', false);
      setAccessField(form, sourceName, 'allowed_list', []);
      setAccessField(form, sourceName, 'denied_list', []);
      setAccessField(form, sourceName, 'max_callers', undefined);
      break;
    case SECURITY_PRESET_ALLOWLIST_STREAMID:
      setAccessField(form, sourceName, 'limit_access', true);
      setAccessField(form, sourceName, 'denied_list', []);
      setAccessField(form, sourceName, 'max_callers', undefined);
      break;
    default:
      break;
  }
};

const SrtAccessFields = ({ sourceName }: SrtAccessFieldsProps) => {
  const form = Form.useFormInstance();

  return (
    <Form.Item noStyle shouldUpdate>
      {({ getFieldValue }) => {
        const schema = getFieldValue(fieldPath(sourceName, 'schema'));
        const mode = getFieldValue(fieldPath(sourceName, 'mode'));

        if (schema !== 'SRT' || mode !== 'listener') {
          return null;
        }

        const securityPreset = detectSecurityPreset(getFieldValue, sourceName);
        const streamidValue = getFieldValue(fieldPath(sourceName, 'streamid'));
        const streamidEmpty = isEmptyString(streamidValue);

        return (
          <>
            <Form.Item
              label="Security preset"
              extra="Choosing a preset only fills the fields below. It is not saved with the route."
            >
              <Select
                allowClear
                aria-label="Security preset"
                placeholder="Custom configuration"
                value={securityPreset}
                options={SECURITY_PRESET_OPTIONS}
                onChange={(value) => {
                  if (value) {
                    applySecurityPreset(form, sourceName, value);
                  }
                }}
              />
            </Form.Item>

            <Form.Item
              label="Max callers"
              name={fieldName(sourceName, 'max_callers')}
              extra="Leave empty to allow any number of simultaneous callers."
            >
              <InputNumber min={1} style={{ width: 180 }} />
            </Form.Item>

            <Form.Item
              label="Expected Stream ID"
              name={fieldName(sourceName, 'streamid')}
              extra="The caller's streamid must match this value. Works alongside the passphrase."
            >
              <Input placeholder="studio-a" />
            </Form.Item>

            <Form.Item
              label="Stream ID match"
              name={fieldName(sourceName, 'streamid_match_mode')}
              extra="Resource mode compares the r= value in Haivision access-control syntax (#!::u=user,r=resource,m=publish)."
            >
              <Select
                disabled={streamidEmpty}
                placeholder="exact"
                options={[
                  { label: 'Exact', value: 'exact' },
                  { label: 'Resource', value: 'resource' },
                  { label: 'Prefix', value: 'prefix' },
                ]}
                style={{ width: 180 }}
              />
            </Form.Item>

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
};

export default SrtAccessFields;
