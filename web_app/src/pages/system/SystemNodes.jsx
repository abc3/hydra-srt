import { useEffect, useState } from 'react';
import { Table, Card, Button, Space, Typography, message, Tooltip, Tag, Progress } from 'antd';
import { ReloadOutlined, HomeOutlined } from '@ant-design/icons';
import { nodesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

const SystemNodes = () => {
  const [nodes, setNodes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();

  // Set breadcrumb items for the System Nodes page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: ROUTES.DASHBOARD,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.SYSTEM_NODES,
          title: 'Nodes List',
        }
      ]);
    }
  }, []);

  useEffect(() => {
    fetchNodes();
    // Set up auto-refresh every 5 seconds
    const intervalId = setInterval(fetchNodes, 5000);
    
    // Clean up interval on component unmount
    return () => clearInterval(intervalId);
  }, []);

  const fetchNodes = async () => {
    try {
      setLoading(true);
      const data = await nodesApi.getAll();
      setNodes(data);
    } catch (error) {
      messageApi.error(`Failed to fetch nodes: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const getStatusColor = (status) => {
    switch (status) {
      case 'up':
        return 'success';
      case 'self':
        return 'processing';
      case 'down':
        return 'error';
      default:
        return 'default';
    }
  };

  const getStatusText = (status) => {
    switch (status) {
      case 'up':
        return 'Up';
      case 'self':
        return 'Self';
      case 'down':
        return 'Down';
      default:
        return 'Unknown';
    }
  };

  const getProgressColor = (value) => {
    if (value === null || value === undefined) return '#ccc';
    if (value > 80) return '#ff4d4f';
    if (value > 50) return '#faad14';
    return '#52c41a';
  };

  const columns = [
    {
      title: 'Host',
      dataIndex: 'host',
      key: 'host',
      render: (text) => <strong>{text}</strong>,
    },
    {
      title: 'CPU',
      dataIndex: 'cpu',
      key: 'cpu',
      render: (value) => {
        if (value === null || value === undefined) return 'N/A';
        return (
          <Progress 
            type="circle"
            percent={Math.round(value)} 
            size={50}
            strokeColor={getProgressColor(value)}
            format={(percent) => `${percent}%`}
          />
        );
      },
      sorter: (a, b) => {
        if (a.cpu === null && b.cpu === null) return 0;
        if (a.cpu === null) return -1;
        if (b.cpu === null) return 1;
        return a.cpu - b.cpu;
      },
    },
    {
      title: 'RAM',
      dataIndex: 'ram',
      key: 'ram',
      render: (value) => {
        if (value === null || value === undefined) return 'N/A';
        return (
          <Progress 
            type="circle"
            percent={Math.round(value)} 
            size={50}
            strokeColor={getProgressColor(value)}
            format={(percent) => `${percent}%`}
          />
        );
      },
      sorter: (a, b) => {
        if (a.ram === null && b.ram === null) return 0;
        if (a.ram === null) return -1;
        if (b.ram === null) return 1;
        return a.ram - b.ram;
      },
    },
    {
      title: 'SWAP',
      dataIndex: 'swap',
      key: 'swap',
      render: (value) => {
        if (value === null || value === undefined) return 'N/A';
        return (
          <Progress 
            type="circle"
            percent={Math.round(value)} 
            size={50}
            strokeColor={getProgressColor(value)}
            format={(percent) => `${percent}%`}
          />
        );
      },
      sorter: (a, b) => {
        if (a.swap === null && b.swap === null) return 0;
        if (a.swap === null) return -1;
        if (b.swap === null) return 1;
        return a.swap - b.swap;
      },
    },
    {
      title: 'LA',
      dataIndex: 'la',
      key: 'la',
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
      render: (status) => (
        <Tag color={getStatusColor(status)}>
          {getStatusText(status)}
        </Tag>
      ),
      filters: [
        { text: 'Self', value: 'self' },
        { text: 'Up', value: 'up' },
        { text: 'Down', value: 'down' },
      ],
      onFilter: (value, record) => record.status === value,
    },
  ];

  return (
    <div>
      {contextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Nodes List</Title>
          <Button
            type="primary"
            icon={<ReloadOutlined />}
            onClick={fetchNodes}
          >
            Refresh
          </Button>
        </Space>

        <Card>
          <Table
            columns={columns}
            dataSource={nodes}
            rowKey="host"
            loading={loading}
            pagination={false}
          />
        </Card>
      </Space>
    </div>
  );
};

export default SystemNodes; 