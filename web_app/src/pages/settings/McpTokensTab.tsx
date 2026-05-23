import { useEffect, useState } from 'react';
import { Button, Card, Form, Input, Modal, Popconfirm, Space, Table, message } from 'antd';
import { CopyOutlined, DeleteOutlined, EditOutlined, PlusOutlined } from '@ant-design/icons';
import type { ColumnsType } from 'antd/es/table';
import { tokensApi } from '../../utils/tokensApi';
import type { McpToken } from '../../types/api';

type TokenFormValues = {
  name: string;
};

type ApiFormError = Error & {
  errorFields?: unknown;
};

const McpTokensTab = () => {
  const [tokens, setTokens] = useState<McpToken[]>([]);
  const [loading, setLoading] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [editingToken, setEditingToken] = useState<McpToken | null>(null);
  const [createdTokenReveal, setCreatedTokenReveal] = useState<string | null>(null);
  const [form] = Form.useForm<TokenFormValues>();
  const [messageApi, contextHolder] = message.useMessage();

  const loadTokens = async () => {
    setLoading(true);
    try {
      const result = await tokensApi.list();
      setTokens(Array.isArray(result.data) ? result.data : []);
    } catch (error) {
      const err = error as Error;
      messageApi.error(`Failed to load tokens: ${err.message}`);
      setTokens([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadTokens();
  }, []);

  const openCreateModal = () => {
    setEditingToken(null);
    form.setFieldsValue({ name: '' });
    setModalOpen(true);
  };

  const openEditModal = (token: McpToken) => {
    setEditingToken(token);
    form.setFieldsValue({ name: token.name });
    setModalOpen(true);
  };

  const closeModal = () => {
    setModalOpen(false);
    setEditingToken(null);
    form.resetFields();
  };

  const handleCopyCreatedToken = async () => {
    if (!createdTokenReveal) {
      return;
    }

    try {
      await navigator.clipboard.writeText(createdTokenReveal);
      messageApi.success('Token copied to clipboard');
    } catch (error) {
      const err = error as Error;
      messageApi.error(`Failed to copy token: ${err.message}`);
    }
  };

  const handleSave = async () => {
    try {
      const values = await form.validateFields();
      setSaving(true);

      if (editingToken?.id) {
        await tokensApi.update(editingToken.id, { name: values.name });
        messageApi.success('Token updated');
        closeModal();
      } else {
        const result = await tokensApi.create({ name: values.name });
        const createdToken = result.data?.token;
        closeModal();

        if (createdToken) {
          setCreatedTokenReveal(createdToken);
        } else {
          messageApi.error('Token was created but the value was not returned. Delete it and create again.');
        }
      }

      await loadTokens();
    } catch (error) {
      const err = error as ApiFormError;
      if (err.errorFields) {
        return;
      }
      messageApi.error(err.message || 'Failed to save token');
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (tokenId: string) => {
    try {
      await tokensApi.delete(tokenId);
      messageApi.success('Token deleted');
      await loadTokens();
    } catch (error) {
      const err = error as Error;
      messageApi.error(`Failed to delete token: ${err.message}`);
    }
  };

  const columns: ColumnsType<McpToken> = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
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
            title="Delete token?"
            description="MCP clients using this token will lose access."
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
        title="MCP tokens"
        extra={(
          <Button type="primary" icon={<PlusOutlined />} onClick={openCreateModal}>
            Add token
          </Button>
        )}
      >
        <Table
          rowKey="id"
          columns={columns}
          dataSource={tokens}
          loading={loading}
          pagination={false}
        />
      </Card>
      <Modal
        title={editingToken ? 'Edit MCP token' : 'Add MCP token'}
        open={modalOpen}
        onOk={handleSave}
        onCancel={closeModal}
        okText="Save"
        cancelText="Cancel"
        confirmLoading={saving}
      >
        <Form form={form} layout="vertical">
          <Form.Item
            label="Name"
            name="name"
            rules={[
              { required: true, message: 'Please enter token name' },
              { whitespace: true, message: 'Token name cannot be empty' },
            ]}
          >
            <Input placeholder="Token name" />
          </Form.Item>
          {!editingToken && (
            <p style={{ marginBottom: 0, color: 'rgba(255, 255, 255, 0.45)' }}>
              A token value will be generated automatically when you save.
            </p>
          )}
        </Form>
      </Modal>
      <Modal
        title="Copy your MCP token"
        open={Boolean(createdTokenReveal)}
        onCancel={() => setCreatedTokenReveal(null)}
        footer={[
          <Button key="copy" type="primary" icon={<CopyOutlined />} onClick={handleCopyCreatedToken}>
            Copy token
          </Button>,
          <Button key="done" onClick={() => setCreatedTokenReveal(null)}>
            Done
          </Button>,
        ]}
        maskClosable={false}
        width={640}
      >
        <Input.TextArea
          value={createdTokenReveal || ''}
          readOnly
          autoSize={{ minRows: 3, maxRows: 6 }}
        />
      </Modal>
    </>
  );
};

export default McpTokensTab;
