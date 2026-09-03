import { useEffect, useState } from 'react';
import { Button, Card, Form, Input, Modal, Popconfirm, Space, Table, message } from 'antd';
import { DeleteOutlined, EditOutlined, PlusOutlined } from '@ant-design/icons';
import type { ColumnsType } from 'antd/es/table';
import type { FieldData } from 'rc-field-form/lib/interface';
import { callerLabelsApi } from '../../utils/callerLabelsApi';
import type { CallerLabel } from '../../types/routes';
import { ipAccessEntryPattern } from '../routes/srtAccessPatterns';

type LabelFormValues = {
  address: string;
  label: string;
  note?: string;
};

type ApiFormError = Error & {
  errorFields?: unknown;
  errors?: Record<string, unknown>;
};

const CallerLabelsTab = () => {
  const [labels, setLabels] = useState<CallerLabel[]>([]);
  const [loading, setLoading] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [editingLabel, setEditingLabel] = useState<CallerLabel | null>(null);
  const [form] = Form.useForm<LabelFormValues>();
  const [messageApi, contextHolder] = message.useMessage();

  const loadLabels = async () => {
    setLoading(true);
    try {
      const result = await callerLabelsApi.list();
      setLabels(Array.isArray(result.data) ? result.data : []);
    } catch (error) {
      const err = error as Error;
      messageApi.error(`Failed to load caller labels: ${err.message}`);
      setLabels([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadLabels();
  }, []);

  const openCreateModal = () => {
    setEditingLabel(null);
    form.setFieldsValue({ address: '', label: '', note: '' });
    setModalOpen(true);
  };

  const openEditModal = (label: CallerLabel) => {
    setEditingLabel(label);
    form.setFieldsValue({
      address: label.address,
      label: label.label,
      note: label.note || '',
    });
    setModalOpen(true);
  };

  const closeModal = () => {
    setModalOpen(false);
    setEditingLabel(null);
    form.resetFields();
  };

  const handleSave = async () => {
    try {
      const values = await form.validateFields();
      setSaving(true);

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

      closeModal();
      await loadLabels();
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
        form.setFields(fields as FieldData<LabelFormValues>[]);
        return;
      }
      messageApi.error(err.message || 'Failed to save caller label');
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (labelId: string) => {
    try {
      await callerLabelsApi.delete(labelId);
      messageApi.success('Caller label deleted');
      await loadLabels();
    } catch (error) {
      const err = error as Error;
      messageApi.error(`Failed to delete caller label: ${err.message}`);
    }
  };

  const columns: ColumnsType<CallerLabel> = [
    {
      title: 'Address',
      dataIndex: 'address',
      key: 'address',
    },
    {
      title: 'Label',
      dataIndex: 'label',
      key: 'label',
    },
    {
      title: 'Note',
      dataIndex: 'note',
      key: 'note',
      render: (value: string | null | undefined) => value || '—',
    },
    {
      title: 'Actions',
      key: 'actions',
      width: 180,
      render: (_, record) => (
        <Space>
          <Button icon={<EditOutlined />} onClick={() => openEditModal(record)}>
            Edit
          </Button>
          <Popconfirm
            title="Delete caller label?"
            description="Routes will no longer show this label for matching callers."
            okText="Delete"
            cancelText="Cancel"
            okButtonProps={{ danger: true }}
            onConfirm={() => handleDelete(record.id)}
          >
            <Button danger icon={<DeleteOutlined />}>
              Delete
            </Button>
          </Popconfirm>
        </Space>
      ),
    },
  ];

  return (
    <>
      {contextHolder}
      <Card
        title="Caller labels"
        extra={(
          <Button type="primary" icon={<PlusOutlined />} onClick={openCreateModal}>
            Add label
          </Button>
        )}
      >
        <Table
          rowKey="id"
          columns={columns}
          dataSource={labels}
          loading={loading}
          pagination={false}
        />
      </Card>
      <Modal
        title={editingLabel ? 'Edit caller label' : 'Add caller label'}
        open={modalOpen}
        onOk={handleSave}
        onCancel={closeModal}
        okText="Save"
        cancelText="Cancel"
        confirmLoading={saving}
      >
        <Form form={form} layout="vertical">
          <Form.Item
            label="Address"
            name="address"
            extra="IP address or CIDR range."
            rules={[
              { required: true, message: 'Please enter an IP address or CIDR range' },
              {
                pattern: ipAccessEntryPattern,
                message: 'Use IP addresses or CIDR ranges only',
              },
            ]}
          >
            <Input placeholder="203.0.113.5 or 10.0.0.0/8" />
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

export default CallerLabelsTab;
