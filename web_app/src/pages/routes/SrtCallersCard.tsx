import { useCallback, useEffect, useState } from 'react';
import {
  Button,
  Card,
  Empty,
  Form,
  Input,
  Modal,
  Popconfirm,
  Space,
  Table,
  message,
} from 'antd';
import type { ColumnsType } from 'antd/es/table';
import type { FieldData } from 'rc-field-form/lib/interface';
import { TagOutlined } from '@ant-design/icons';
import { routesApi } from '../../utils/api';
import { callerLabelsApi } from '../../utils/callerLabelsApi';
import { subscribeToStats } from '../../utils/realtime';
import type { CallerLabel, SrtCallerStats } from '../../types/routes';
import { srtNumeric, formatSrtLinkRate, formatSrtMetricDisplay } from './srtHealthFormatters';
import { ipAccessEntryPattern } from './srtAccessPatterns';

type ApiFormError = Error & {
  errorFields?: unknown;
  errors?: Record<string, unknown>;
};

type LabelFormValues = {
  address: string;
  label: string;
  note?: string;
};

type SrtCallersCardProps = {
  routeId: string;
  routeActive?: boolean;
};

const EMPTY_METRIC = '—';

const parseCallerIp = (callerAddress: string): string => {
  const match = callerAddress.match(/^(.+):(\d+)$/);
  return match ? match[1] : callerAddress;
};

const formatDuration = (seconds: number | null | undefined): string => {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) {
    return EMPTY_METRIC;
  }

  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;

  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  if (minutes > 0) {
    return `${minutes}m ${secs}s`;
  }
  return `${secs}s`;
};

const SrtCallersCard = ({ routeId, routeActive = true }: SrtCallersCardProps) => {
  const [callers, setCallers] = useState<SrtCallerStats[]>([]);
  const [initialLoading, setInitialLoading] = useState(true);
  const [initialError, setInitialError] = useState<string | null>(null);
  const [labelModalOpen, setLabelModalOpen] = useState(false);
  const [labelSaving, setLabelSaving] = useState(false);
  const [labelTarget, setLabelTarget] = useState<SrtCallerStats | null>(null);
  const [editingLabel, setEditingLabel] = useState<CallerLabel | null>(null);
  const [labelForm] = Form.useForm<LabelFormValues>();
  const [messageApi, contextHolder] = message.useMessage();

  const loadInitialCallers = useCallback(async () => {
    setInitialLoading(true);
    setInitialError(null);
    try {
      const result = await routesApi.getSrtCallers(routeId);
      setCallers(Array.isArray(result?.data) ? result.data : []);
    } catch (error) {
      const err = error as Error;
      setInitialError(err.message || 'Failed to load SRT callers');
      setCallers([]);
    } finally {
      setInitialLoading(false);
    }
  }, [routeId]);

  useEffect(() => {
    loadInitialCallers();
  }, [loadInitialCallers]);

  useEffect(() => {
    const unsubscribe = subscribeToStats((payload) => {
      if (payload?.route_id !== routeId || payload?.metric !== 'snapshot' || !payload?.stats) {
        return;
      }

      const stats = payload.stats as {
        callers?: SrtCallerStats[];
      };

      if (!Array.isArray(stats.callers)) {
        return;
      }

      // Every snapshot carries the complete caller list, so a caller that is gone
      // from it has disconnected and must leave the table.
      setCallers(stats.callers as SrtCallerStats[]);
    });

    return unsubscribe;
  }, [routeId]);

  const loadLabelCatalog = async (): Promise<CallerLabel[]> => {
    const result = await callerLabelsApi.list();
    return Array.isArray(result.data) ? result.data : [];
  };

  const openLabelModal = async (caller: SrtCallerStats) => {
    const ip = parseCallerIp(caller['caller-address']);
    setLabelTarget(caller);

    try {
      const catalog = await loadLabelCatalog();
      const existing = catalog.find((entry) => entry.address === ip) || null;
      setEditingLabel(existing);
      labelForm.setFieldsValue({
        address: ip,
        label: existing?.label || caller.label || '',
        note: existing?.note || '',
      });
      setLabelModalOpen(true);
    } catch (error) {
      const err = error as Error;
      messageApi.error(`Failed to load caller labels: ${err.message}`);
    }
  };

  const closeLabelModal = () => {
    setLabelModalOpen(false);
    setLabelTarget(null);
    setEditingLabel(null);
    labelForm.resetFields();
  };

  const handleLabelSave = async () => {
    try {
      const values = await labelForm.validateFields();
      setLabelSaving(true);

      if (editingLabel?.id) {
        await callerLabelsApi.update(editingLabel.id, {
          address: values.address,
          label: values.label,
          note: values.note || null,
        });
        messageApi.success('Caller label updated');
      } else {
        await callerLabelsApi.create({
          address: values.address,
          label: values.label,
          note: values.note || null,
        });
        messageApi.success('Caller label created');
      }

      closeLabelModal();
      await loadLabelCatalog();
      await loadInitialCallers();
    } catch (error) {
      const err = error as ApiFormError;
      if (err.errorFields) {
        return;
      }
      if (err.errors && typeof err.errors === 'object') {
        const fields = Object.entries(err.errors).map(([name, msgs]) => ({
          name,
          errors: Array.isArray(msgs) ? msgs.map(String) : [String(msgs)],
        }));
        labelForm.setFields(fields as FieldData<LabelFormValues>[]);
        return;
      }
      messageApi.error(err.message || 'Failed to save caller label');
    } finally {
      setLabelSaving(false);
    }
  };

  const handleBan = async (caller: SrtCallerStats) => {
    const ip = parseCallerIp(caller['caller-address']);
    try {
      await routesApi.banSrtCaller(routeId, ip);
      messageApi.success(`Added ${ip} to the deny list. The ban applies on the caller's next connection attempt.`);
    } catch (error) {
      const err = error as Error;
      messageApi.error(err.message || 'Failed to ban caller');
    }
  };

  const columns: ColumnsType<SrtCallerStats> = [
    {
      title: 'Address',
      dataIndex: 'caller-address',
      key: 'address',
      render: (_, record) => record['caller-address'],
    },
    {
      title: 'Label',
      key: 'label',
      render: (_, record) => record.label ?? EMPTY_METRIC,
    },
    {
      title: 'Stream ID',
      key: 'stream-id',
      render: (_, record) => record['stream-id'] ?? EMPTY_METRIC,
    },
    {
      title: 'Duration',
      key: 'duration',
      render: (_, record) => formatDuration(record.duration_seconds),
    },
    {
      title: 'RTT',
      key: 'rtt',
      render: (_, record) => {
        const value = srtNumeric(record['rtt-ms']);
        return value === null ? EMPTY_METRIC : `${value.toFixed(2)} ms`;
      },
    },
    {
      title: 'Loss %',
      key: 'loss',
      render: (_, record) => {
        const value = srtNumeric(record['packet-loss-percent']);
        return value === null ? EMPTY_METRIC : `${value.toFixed(2)}%`;
      },
    },
    {
      title: 'Retransmitted/s',
      key: 'retransmitted',
      render: (_, record) => formatSrtMetricDisplay(record['retransmitted-packets-per-sec']),
    },
    {
      title: 'Dropped/s',
      key: 'dropped',
      render: (_, record) => formatSrtMetricDisplay(record['dropped-packets-per-sec']),
    },
    {
      title: 'Rate',
      key: 'rate',
      render: (_, record) => {
        const value = srtNumeric(record['receive-rate-mbps']);
        return value === null ? EMPTY_METRIC : formatSrtLinkRate(value);
      },
    },
    {
      title: 'Actions',
      key: 'actions',
      width: 200,
      render: (_, record) => (
        <Space>
          <Button icon={<TagOutlined />} onClick={() => openLabelModal(record)}>
            Label
          </Button>
          <Popconfirm
            title="Ban this caller?"
            description="SRT cannot disconnect a live caller. This adds the IP to the deny list and the ban applies on the caller's next connection attempt."
            okText="Ban"
            cancelText="Cancel"
            okButtonProps={{ danger: true }}
            onConfirm={() => handleBan(record)}
          >
            <Button danger>Ban</Button>
          </Popconfirm>
        </Space>
      ),
    },
  ];

  const showEmpty = !routeActive || callers.length === 0;

  return (
    <>
      {contextHolder}
      <Card
        size="small"
        title="Connected callers"
        style={{ marginBottom: 16 }}
        loading={initialLoading}
      >
        {initialError && (
          <div style={{ marginBottom: 12, color: '#ff4d4f' }}>{initialError}</div>
        )}
        {showEmpty ? (
          <Empty
            description={
              !routeActive
                ? 'Route is stopped. Connected caller metrics are unavailable.'
                : 'No callers are connected to this listener.'
            }
          />
        ) : (
          <Table
            rowKey="caller-address"
            columns={columns}
            dataSource={callers}
            pagination={false}
            size="small"
          />
        )}
      </Card>
      <Modal
        title={editingLabel ? 'Edit caller label' : 'Add caller label'}
        open={labelModalOpen}
        onOk={handleLabelSave}
        onCancel={closeLabelModal}
        okText="Save"
        cancelText="Cancel"
        confirmLoading={labelSaving}
      >
        <Form form={labelForm} layout="vertical">
          <Form.Item
            label="Address"
            name="address"
            rules={[
              { required: true, message: 'Please enter an IP address or CIDR range' },
              {
                pattern: ipAccessEntryPattern,
                message: 'Use IP addresses or CIDR ranges only',
              },
            ]}
          >
            <Input placeholder="203.0.113.5 or 10.0.0.0/8" disabled={Boolean(labelTarget)} />
          </Form.Item>
          <Form.Item
            label="Label"
            name="label"
            rules={[
              { required: true, message: 'Please enter a label' },
              { whitespace: true, message: 'Label cannot be empty' },
            ]}
          >
            <Input placeholder="Studio A uplink" />
          </Form.Item>
          <Form.Item label="Note" name="note">
            <Input.TextArea rows={3} placeholder="Optional note" />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
};

export default SrtCallersCard;
