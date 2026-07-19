import { Alert, Form, Input, Select, Space, Typography } from 'antd';
import { useEffect, useMemo, useState } from 'react';
import type { NdiCapabilities, NdiSourceRow } from '../../types/ndi';
import { ndiApi } from '../../utils/ndiApi';
import NdiCapabilityAlert from './NdiCapabilityAlert';
import NdiTrademarkNotice from './NdiTrademarkNotice';
import {
  NDI_MEDIA_POLICIES,
  NDI_OUTPUT_FORMAT_STATEMENT,
  NDI_SENDER_NAME_GUIDANCE,
} from './ndiConstants';
import { isNdiRunnable } from './ndiCapabilityState';

const { Text } = Typography;

type ListName = 'sources' | 'destinations';

type Props = {
  namePrefix?: number;
  listName?: ListName;
  capabilities: NdiCapabilities | null;
  capabilitiesLoading?: boolean;
  /** Other destination sender names in the same route (local collision). */
  siblingSenderNames?: string[];
};

const fieldName = (namePrefix: number | undefined, key: string) =>
  namePrefix === undefined ? key : [namePrefix, key];

const fieldPath = (listName: ListName | undefined, namePrefix: number | undefined, key: string) => {
  if (namePrefix === undefined) {
    return key;
  }
  return [listName ?? 'destinations', namePrefix, key];
};

const normalizeSenderKey = (name: string) =>
  name.trim().toLowerCase().replace(/\s+/g, ' ');

const NdiOutputFields = ({
  namePrefix,
  listName = 'destinations',
  capabilities,
  capabilitiesLoading = false,
  siblingSenderNames = [],
}: Props) => {
  const form = Form.useFormInstance();
  const senderName = Form.useWatch(fieldPath(listName, namePrefix, 'ndi_sender_name'), form) as string | undefined;
  const [externalNames, setExternalNames] = useState<NdiSourceRow[]>([]);
  const [externalWarning, setExternalWarning] = useState<string | null>(null);

  useEffect(() => {
    if (!capabilities?.feature_enabled || !isNdiRunnable(capabilities, 'discovery')) {
      return;
    }

    let mounted = true;
    const timer = setTimeout(() => {
      void ndiApi
        .listSources({})
        .then((response) => {
          if (mounted) {
            setExternalNames(Array.isArray(response.data) ? response.data : []);
          }
        })
        .catch(() => {
          if (mounted) {
            setExternalNames([]);
          }
        });
    }, 400);

    return () => {
      mounted = false;
      clearTimeout(timer);
    };
  }, [capabilities]);

  useEffect(() => {
    const trimmed = (senderName || '').trim();
    if (!trimmed) {
      setExternalWarning(null);
      return;
    }

    const key = normalizeSenderKey(trimmed);
    const hit = externalNames.find((row) => normalizeSenderKey(row.name) === key);
    if (hit) {
      setExternalWarning(
        `Best-effort warning: discovery currently sees an external sender named "${hit.display_name || hit.name}". This is not a reservation.`,
      );
    } else {
      setExternalWarning(null);
    }
  }, [senderName, externalNames]);

  const localCollision = useMemo(() => {
    const trimmed = (senderName || '').trim();
    if (!trimmed) {
      return false;
    }
    const key = normalizeSenderKey(trimmed);
    return siblingSenderNames.some((name) => normalizeSenderKey(String(name || '')) === key);
  }, [senderName, siblingSenderNames]);

  return (
    <>
      <NdiCapabilityAlert
        capabilities={capabilities}
        loading={capabilitiesLoading}
        direction="send"
      />

      <Form.Item
        label="Sender name"
        name={fieldName(namePrefix, 'ndi_sender_name')}
        rules={[
          { required: true, message: 'Enter an NDI sender name' },
          {
            validator: async (_, value?: string) => {
              const trimmed = String(value || '').trim();
              if (!trimmed) {
                return;
              }
              const key = normalizeSenderKey(trimmed);
              const conflict = siblingSenderNames.some(
                (name) => normalizeSenderKey(String(name || '')) === key,
              );
              if (conflict) {
                throw new Error('This sender name collides with another destination on this route');
              }
            },
          },
        ]}
        extra={NDI_SENDER_NAME_GUIDANCE}
      >
        <Input placeholder="Hydra (Route Output)" aria-label="NDI sender name" />
      </Form.Item>

      {localCollision && (
        <Alert
          type="error"
          showIcon
          style={{ marginBottom: 12 }}
          message="Local sender-name collision"
          description="Another destination on this route already uses this sender name. Save will reject the duplicate."
        />
      )}

      {externalWarning && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 12 }}
          message="External discovery collision (best-effort)"
          description={externalWarning}
        />
      )}

      <Form.Item
        label="Media policy"
        name={fieldName(namePrefix, 'ndi_media_policy')}
        initialValue="video_and_audio_required"
        rules={[{ required: true, message: 'Select a media policy' }]}
      >
        <Select
          options={NDI_MEDIA_POLICIES.map((value) => ({ label: value, value }))}
         
        />
      </Form.Item>

      <Space direction="vertical" size={4} style={{ marginBottom: 12, width: '100%' }}>
        <Text strong>Output format</Text>
        <Text>{NDI_OUTPUT_FORMAT_STATEMENT}</Text>
        <Text type="secondary">
          Node discovery uses mDNS when available. Direct-address and NIC policy are controlled in system configuration — this form does not edit global network settings.
        </Text>
      </Space>

      <NdiTrademarkNotice />
    </>
  );
};

export default NdiOutputFields;
