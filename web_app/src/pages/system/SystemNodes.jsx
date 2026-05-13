import { useEffect, useState } from 'react';
import { Table, Card, Space, Typography, Progress, theme } from 'antd';
import { ArrowDownOutlined, ArrowUpOutlined, HomeOutlined } from '@ant-design/icons';
import { Link } from 'react-router-dom';
import { subscribeToNodes } from '../../utils/realtime';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

const SystemNodes = () => {
  const { token } = theme.useToken();
  const [nodes, setNodes] = useState([]);
  const [loading, setLoading] = useState(true);

  // Set breadcrumb items for the System Nodes page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
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
    return subscribeToNodes((payload) => {
      if (Array.isArray(payload?.nodes)) {
        setNodes(payload.nodes);
        setLoading(false);
      }
    });
  }, []);

  const getProgressColor = (value) => {
    if (value === null || value === undefined) return '#ccc';
    if (value > 80) return '#ff4d4f';
    if (value > 50) return '#faad14';
    return '#52c41a';
  };

  const formatThroughput = (bytesPerSec) => {
    if (bytesPerSec === null || bytesPerSec === undefined || Number.isNaN(bytesPerSec)) {
      return 'N/A';
    }

    const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
    let value = Math.max(0, Number(bytesPerSec) * 8);
    let unitIndex = 0;

    while (value >= 1000 && unitIndex < units.length - 1) {
      value /= 1000;
      unitIndex += 1;
    }

    const precision = value >= 100 ? 0 : value >= 10 ? 1 : 2;
    return `${value.toFixed(precision)} ${units[unitIndex]}`;
  };

  const formatHostOnly = (value) => {
    if (!value) return 'N/A';
    const text = String(value);
    const [, host] = text.split('@');
    return host || text;
  };

  const columns = [
    {
      title: 'Host',
      dataIndex: 'host',
      key: 'host',
      render: (text) => (
        <Link to={`/system/nodes/${encodeURIComponent(String(text || ''))}`}>
          <strong>{formatHostOnly(text)}</strong>
        </Link>
      ),
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
      title: 'Network In / Out',
      key: 'network',
      render: (_, record) => (
        <Space size={12}>
          <span style={{ color: token.colorSuccess, whiteSpace: 'nowrap' }}>
            <ArrowDownOutlined /> {formatThroughput(record.network_in_bytes_per_sec)}
          </span>
          <span style={{ color: token.colorPrimary, whiteSpace: 'nowrap' }}>
            <ArrowUpOutlined /> {formatThroughput(record.network_out_bytes_per_sec)}
          </span>
        </Space>
      ),
      sorter: (a, b) => {
        const aTotal = (a.network_in_bytes_per_sec || 0) + (a.network_out_bytes_per_sec || 0);
        const bTotal = (b.network_in_bytes_per_sec || 0) + (b.network_out_bytes_per_sec || 0);
        return aTotal - bTotal;
      },
    },
  ];

  return (
    <div>
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Nodes List</Title>

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
