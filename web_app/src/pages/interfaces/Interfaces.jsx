import { useEffect, useState } from 'react';
import {
  Card,
  Table,
  Typography,
  Space,
  Button,
  Input,
  Drawer,
  message,
  Tag,
  Switch,
  Tooltip,
} from 'antd';
import {
  HomeOutlined,
  FileTextOutlined,
  InfoCircleOutlined,
} from '@ant-design/icons';
import { interfacesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

const Interfaces = () => {
  const [interfaces, setInterfaces] = useState([]);
  const [loading, setLoading] = useState(true);
  const [editingKey, setEditingKey] = useState('');
  const [editingName, setEditingName] = useState('');
  const [savingKey, setSavingKey] = useState('');
  const [togglingKey, setTogglingKey] = useState('');
  const [rawInfo, setRawInfo] = useState('');
  const [rawInfoLoading, setRawInfoLoading] = useState(false);
  const [rawInfoOpen, setRawInfoOpen] = useState(false);
  const [messageApi, contextHolder] = message.useMessage();

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.INTERFACES,
          title: 'Interfaces',
        },
      ]);
    }
  }, []);

  useEffect(() => {
    fetchInterfaces();
  }, []);

  const fetchInterfaces = async () => {
    try {
      setLoading(true);
      const [savedResult, systemResult] = await Promise.all([
        interfacesApi.getAll(),
        interfacesApi.getSystemInterfaces(),
      ]);

      const saved = Array.isArray(savedResult.data) ? savedResult.data : [];
      const system = Array.isArray(systemResult.data) ? systemResult.data : [];

      const savedBySysName = saved.reduce((acc, item) => {
        if (item?.sys_name) {
          acc[item.sys_name] = item;
        }
        return acc;
      }, {});

      const systemRows = system.map((item) => {
        const aliasRecord = savedBySysName[item.sys_name];

        return {
          key: aliasRecord?.id || `system:${item.sys_name}`,
          id: aliasRecord?.id || null,
          name: aliasRecord?.name || '',
          sys_name: item.sys_name,
          ip: item.ip,
          multicast_supported: item.multicast_supported,
          raw_description: item.raw_description,
          enabled: aliasRecord?.enabled ?? true,
          source: 'system',
        };
      });

      const missingSavedRows = saved
        .filter((item) => !system.some((systemItem) => systemItem.sys_name === item.sys_name))
        .map((item) => ({
          key: item.id,
          id: item.id,
          name: item.name,
          sys_name: item.sys_name,
          ip: item.ip,
          multicast_supported: false,
          raw_description: '',
          enabled: item.enabled ?? true,
          source: 'custom',
        }));

      setInterfaces([...systemRows, ...missingSavedRows]);
    } catch (error) {
      messageApi.error(`Failed to fetch interfaces: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const openRawInfoDrawer = async () => {
    try {
      setRawInfoLoading(true);
      const result = await interfacesApi.getSystemRaw();
      setRawInfo(result?.data?.raw || '');
      setRawInfoOpen(true);
    } catch (error) {
      messageApi.error(`Failed to fetch raw interface info: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setRawInfoLoading(false);
    }
  };

  const startEdit = (record) => {
    setEditingKey(record.key);
    setEditingName(record.name || '');
  };

  const cancelEdit = () => {
    setEditingKey('');
    setEditingName('');
  };

  const saveName = async (record, options = {}) => {
    const { silentIfEmpty = false } = options;
    const nextName = editingName.trim();

    if (!nextName) {
      if (silentIfEmpty) {
        cancelEdit();
        return;
      }
      messageApi.error('Name cannot be empty');
      return;
    }

    try {
      setSavingKey(record.key);
      const payload = {
        name: nextName,
        sys_name: record.sys_name,
        ip: record.ip,
        enabled: record.enabled ?? true,
      };

      if (record.id) {
        await interfacesApi.update(record.id, payload);
      } else {
        await interfacesApi.create(payload);
      }

      messageApi.success('Interface name saved');
      cancelEdit();
      fetchInterfaces();
    } catch (error) {
      messageApi.error(`Failed to save interface name: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setSavingKey('');
    }
  };

  const toggleEnabled = async (record, enabled) => {
    try {
      setTogglingKey(record.key);
      const normalizedName =
        typeof record.name === 'string' && record.name.trim() !== ''
          ? record.name.trim()
          : null;

      const payload = {
        name: normalizedName,
        sys_name: record.sys_name,
        ip: record.ip,
        enabled,
      };

      if (record.id) {
        await interfacesApi.update(record.id, payload);
      } else {
        await interfacesApi.create(payload);
      }

      messageApi.success(
        `Interface "${record.sys_name}" is now ${enabled ? 'visible' : 'hidden'} in selector lists`
      );
      await fetchInterfaces();
    } catch (error) {
      messageApi.error(`Failed to update interface visibility: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setTogglingKey('');
    }
  };

  const columns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => (a.name || '').localeCompare(b.name || ''),
      render: (value, record) => {
        const isEditing = editingKey === record.key;
        if (isEditing) {
          return (
            <Input
              autoFocus
              size="small"
              value={editingName}
              disabled={savingKey === record.key}
              onChange={(event) => setEditingName(event.target.value)}
              onPressEnter={() => saveName(record)}
              onBlur={() => saveName(record, { silentIfEmpty: true })}
              onKeyDown={(event) => {
                if (event.key === 'Escape') {
                  cancelEdit();
                }
              }}
            />
          );
        }

        return (
          <div
            onClick={() => startEdit(record)}
            style={{ cursor: 'text', minHeight: 22 }}
            title="Click to edit name"
          >
            {value ? value : <Typography.Text type="secondary">Click to set</Typography.Text>}
          </div>
        );
      },
    },
    {
      title: 'System Name',
      dataIndex: 'sys_name',
      key: 'sys_name',
      sorter: (a, b) => (a.sys_name || '').localeCompare(b.sys_name || ''),
    },
    {
      title: 'IP',
      dataIndex: 'ip',
      key: 'ip',
      sorter: (a, b) => (a.ip || '').localeCompare(b.ip || ''),
    },
    {
      title: 'Multicast',
      dataIndex: 'multicast_supported',
      key: 'multicast_supported',
      sorter: (a, b) => Number(a.multicast_supported) - Number(b.multicast_supported),
      render: (_, record) => {
        if (record.source !== 'system') {
          return <Tag>Unknown</Tag>;
        }

        return record.multicast_supported ? <Tag color="green">Yes</Tag> : <Tag color="red">No</Tag>;
      },
    },
    {
      title: (
        <Space size={6}>
          <span>Show in list</span>
          <Tooltip title="Controls whether this interface appears in interface selector lists.">
            <InfoCircleOutlined />
          </Tooltip>
        </Space>
      ),
      dataIndex: 'enabled',
      key: 'enabled',
      width: 150,
      render: (_, record) => (
        <Switch
          checked={record.enabled !== false}
          loading={togglingKey === record.key}
          onChange={(checked) => toggleEnabled(record, checked)}
        />
      ),
    },
  ];

  return (
    <div>
      {contextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <div>
            <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Interfaces</Title>
            <Typography.Text type="secondary">
              System interfaces are discovered automatically. Click Name to set or edit an alias.
            </Typography.Text>
          </div>
          <Button
            icon={<FileTextOutlined />}
            onClick={openRawInfoDrawer}
            loading={rawInfoLoading}
          >
            ifconfig
          </Button>
        </Space>

        <Card>
          <Table
            columns={columns}
            dataSource={interfaces}
            rowKey="key"
            loading={loading}
            pagination={false}
          />
        </Card>
      </Space>
      <Drawer
        title="Raw ifconfig Output"
        open={rawInfoOpen}
        onClose={() => setRawInfoOpen(false)}
        width={720}
      >
        {rawInfo ? (
          <pre
            style={{
              margin: 0,
              padding: 12,
              borderRadius: 8,
              border: '1px solid #303030',
              background: '#141414',
              overflow: 'auto',
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
            }}
          >
            {rawInfo}
          </pre>
        ) : (
          <Typography.Text type="secondary">
            No raw interface info available.
          </Typography.Text>
        )}
      </Drawer>
    </div>
  );
};

export default Interfaces;
