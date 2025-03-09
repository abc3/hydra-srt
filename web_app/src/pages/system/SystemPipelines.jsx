import { useEffect, useState } from 'react';
import { Table, Card, Button, Space, Typography, message, Modal, Tooltip, Tag } from 'antd';
import { ReloadOutlined, StopOutlined, ExclamationCircleFilled, HomeOutlined } from '@ant-design/icons';
import { systemPipelinesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

const SystemPipelines = () => {
  const [pipelines, setPipelines] = useState([]);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();

  // Set breadcrumb items for the System Pipelines page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: ROUTES.DASHBOARD,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.SYSTEM_PIPELINES,
          title: 'System Pipelines',
        }
      ]);
    }
  }, []);

  useEffect(() => {
    fetchPipelines();
    // Set up auto-refresh every 5 seconds
    const intervalId = setInterval(fetchPipelines, 5000);
    
    // Clean up interval on component unmount
    return () => clearInterval(intervalId);
  }, []);

  const fetchPipelines = async () => {
    try {
      setLoading(true);
      const data = await systemPipelinesApi.getAll();
      setPipelines(data);
    } catch (error) {
      messageApi.error(`Failed to fetch pipeline processes: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const showKillConfirm = (record) => {
    modal.confirm({
      title: 'Are you sure you want to force kill this pipeline process?',
      icon: <ExclamationCircleFilled />,
      content: `PID: ${record.pid}, Command: ${record.command}`,
      okText: 'Yes, kill',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return handleKill(record.pid);
      },
    });
  };

  const handleKill = async (pid) => {
    try {
      await systemPipelinesApi.kill(pid);
      messageApi.success('Pipeline process killed successfully');
      fetchPipelines(); // Refresh the list
    } catch (error) {
      messageApi.error(`Failed to kill process: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const formatBytes = (bytes, decimals = 2) => {
    if (bytes === 0) return '0 Bytes';
    
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return parseFloat((bytes / Math.pow(1024, i)).toFixed(decimals)) + ' ' + sizes[i];
  };

  const columns = [
    {
      title: 'PID',
      dataIndex: 'pid',
      key: 'pid',
      sorter: (a, b) => a.pid - b.pid,
    },
    {
      title: 'CPU',
      dataIndex: 'cpu',
      key: 'cpu',
      sorter: (a, b) => parseFloat(a.cpu) - parseFloat(b.cpu),
      render: (text) => {
        const value = parseFloat(text);
        let color = 'green';
        if (value > 50) color = 'orange';
        if (value > 80) color = 'red';
        return <Tag color={color}>{text}</Tag>;
      }
    },
    {
      title: 'Memory',
      dataIndex: 'memory',
      key: 'memory',
      render: (_, record) => (
        <Tooltip title={`${record.memory_bytes} bytes (${record.memory_percent})`}>
          {record.memory}
        </Tooltip>
      ),
      sorter: (a, b) => a.memory_bytes - b.memory_bytes,
    },
    {
      title: 'Swap',
      key: 'swap',
      render: (_, record) => (
        <Tooltip title={`${record.swap_bytes} bytes`}>
          {formatBytes(record.swap_bytes)} ({record.swap_percent})
        </Tooltip>
      ),
      sorter: (a, b) => a.swap_bytes - b.swap_bytes,
    },
    {
      title: 'User',
      dataIndex: 'user',
      key: 'user',
    },
    {
      title: 'Start Time',
      dataIndex: 'start_time',
      key: 'start_time',
    },
    {
      title: 'Command',
      dataIndex: 'command',
      key: 'command',
      ellipsis: true,
      render: (text) => (
        <Tooltip title={text}>
          {text}
        </Tooltip>
      ),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => (
        <Button
          type="primary"
          danger
          icon={<StopOutlined />}
          onClick={() => showKillConfirm(record)}
        >
          Force Kill
        </Button>
      ),
    },
  ];

  const expandedRowRender = (record) => {
    const items = [
      { label: 'PID', value: record.pid },
      { label: 'CPU Usage', value: record.cpu },
      { label: 'Memory Usage', value: `${record.memory} (${record.memory_percent})` },
      { label: 'Memory in Bytes', value: record.memory_bytes.toLocaleString() },
      { label: 'Swap Usage', value: `${formatBytes(record.swap_bytes)} (${record.swap_percent})` },
      { label: 'Swap in Bytes', value: record.swap_bytes.toLocaleString() },
      { label: 'User', value: record.user },
      { label: 'Start Time', value: record.start_time },
      { label: 'Command', value: record.command },
    ];

    if (record.virtual_memory) {
      items.push({ label: 'Virtual Memory', value: record.virtual_memory });
      items.push({ label: 'Resident Memory', value: record.resident_memory });
      items.push({ label: 'CPU Time', value: record.cpu_time });
      items.push({ label: 'Process State', value: record.state });
      items.push({ label: 'Parent PID', value: record.ppid });
    }

    return (
      <Card title="Detailed Information">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '16px' }}>
          {items.map((item, index) => (
            <div key={index}>
              <strong>{item.label}:</strong> {item.value}
            </div>
          ))}
        </div>
      </Card>
    );
  };

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>System Pipelines</Title>
          <Button
            type="primary"
            icon={<ReloadOutlined />}
            onClick={fetchPipelines}
          >
            Refresh
          </Button>
        </Space>

        <Card>
          <Table
            columns={columns}
            dataSource={pipelines}
            rowKey="pid"
            loading={loading}
            expandable={{
              expandedRowRender,
              expandRowByClick: true,
            }}
            pagination={{
              defaultPageSize: 10,
              showSizeChanger: true,
              showTotal: (total) => `Total ${total} pipeline processes`,
            }}
          />
        </Card>
      </Space>
    </div>
  );
};

export default SystemPipelines; 