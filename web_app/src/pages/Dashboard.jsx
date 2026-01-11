import { Typography, Card, Row, Col, Statistic, Progress, Table, Space } from 'antd';
import { HomeOutlined } from '@ant-design/icons';
import { useEffect, useState } from 'react';
import React from 'react';
import { dashboardApi, nodesApi } from '../utils/api';
import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip, Legend } from 'recharts';

const { Title } = Typography;

const Dashboard = () => {
  const [summary, setSummary] = useState(null);
  const [nodes, setNodes] = useState([]);
  const [loading, setLoading] = useState(true);

  // Set breadcrumb items for the Dashboard page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        }
      ]);
    }
  }, []);

  const getProgressColor = (value) => {
    if (value === null || value === undefined) return '#ccc';
    if (value > 80) return '#ff4d4f';
    if (value > 50) return '#faad14';
    return '#52c41a';
  };

  const formatBps = (bps) => {
    if (bps == null || Number.isNaN(bps)) return 'N/A';
    const v = Number(bps);
    if (!Number.isFinite(v)) return 'N/A';
    if (v >= 1e9) return `${(v / 1e9).toFixed(2)} Gbps`;
    if (v >= 1e6) return `${(v / 1e6).toFixed(2)} Mbps`;
    if (v >= 1e3) return `${(v / 1e3).toFixed(2)} Kbps`;
    return `${Math.round(v)} bps`;
  };

  const bpsFromBytesPerSec = (bytesPerSec) => {
    if (bytesPerSec == null) return null;
    const v = Number(bytesPerSec);
    if (!Number.isFinite(v)) return null;
    return v * 8;
  };

  // Fetch dashboard summary + nodes list
  useEffect(() => {
    const fetchSummary = async () => {
      try {
        setLoading(true);
        const data = await dashboardApi.getSummary();
        setSummary(data);
      } catch (error) {
        console.error('Error fetching dashboard summary:', error);
      } finally {
        setLoading(false);
      }
    };

    const fetchNodes = async () => {
      try {
        const data = await nodesApi.getAll();
        setNodes(Array.isArray(data) ? data : []);
      } catch (error) {
        console.error('Error fetching nodes:', error);
      }
    };

    fetchSummary();
    fetchNodes();

    // Poll dashboard summary every 10 seconds
    const summaryIntervalId = setInterval(fetchSummary, 10000);

    // Refresh nodes every 30 seconds
    const nodesIntervalId = setInterval(fetchNodes, 30000);
    
    // Clean up interval on component unmount
    return () => {
      clearInterval(summaryIntervalId);
      clearInterval(nodesIntervalId);
    };
  }, []);

  const routePieData = [
    { name: 'Started', value: summary?.routes?.started ?? 0 },
    { name: 'Stopped', value: summary?.routes?.stopped ?? 0 },
  ];

  const pieColors = ['#52c41a', '#ff4d4f'];

  const nodesColumns = [
    { title: 'Host', dataIndex: 'host', key: 'host' },
    { title: 'Status', dataIndex: 'status', key: 'status' },
    { title: 'CPU %', dataIndex: 'cpu', key: 'cpu', render: (v) => (typeof v === 'number' ? Math.round(v) : 'N/A') },
    { title: 'RAM %', dataIndex: 'ram', key: 'ram', render: (v) => (typeof v === 'number' ? Math.round(v) : 'N/A') },
    { title: 'SWAP %', dataIndex: 'swap', key: 'swap', render: (v) => (typeof v === 'number' ? Math.round(v) : 'N/A') },
    { title: 'LA (1/5/15)', dataIndex: 'la', key: 'la' },
  ];

  const enabledNotStarted =
    summary?.routes
      ? Math.max((summary.routes.enabled ?? 0) - (summary.routes.started ?? 0), 0)
      : null;

  const inBps = bpsFromBytesPerSec(summary?.throughput?.in_bytes_per_sec);
  const outBps = bpsFromBytesPerSec(summary?.throughput?.out_bytes_per_sec);

  const selfNode = nodes.find((n) => n?.status === 'self');
  const cpu = selfNode?.cpu ?? summary?.system?.cpu ?? null;
  const ram = selfNode?.ram ?? summary?.system?.ram ?? null;
  const swap = selfNode?.swap ?? summary?.system?.swap ?? null;
  const la = selfNode?.la ?? summary?.system?.la ?? 'N/A / N/A / N/A';

  return (
    <div>
      <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Dashboard</Title>

      <Row gutter={[16, 16]}>
        <Col xs={24} sm={6}>
          <Card>
            <Statistic title="Total Routes" value={summary?.routes?.total ?? 0} loading={loading} />
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <Statistic title="Started Routes" value={summary?.routes?.started ?? 0} loading={loading} />
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <Statistic title="Stopped Routes" value={summary?.routes?.stopped ?? 0} loading={loading} />
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <Statistic title="Pipelines (OS)" value={summary?.pipelines?.count ?? 0} loading={loading} />
          </Card>
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>CPU Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{cpu !== null ? `${Math.round(cpu)}%` : 'N/A'}</div>
              <div style={{ display: 'flex', justifyContent: 'center', marginTop: '16px' }}>
                {/* <Progress
                  type="circle"
                  percent={cpu !== null ? Math.round(cpu) : 0}
                  size={120}
                  strokeColor={getProgressColor(cpu)}
                  format={(percent) => (cpu !== null ? `${percent}%` : 'N/A')}
                /> */}
              </div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>RAM Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{ram !== null ? `${Math.round(ram)}%` : 'N/A'}</div>
              <div style={{ display: 'flex', justifyContent: 'center', marginTop: '16px' }}>
                {/* <Progress
                  type="circle"
                  percent={ram !== null ? Math.round(ram) : 0}
                  size={120}
                  strokeColor={getProgressColor(ram)}
                  format={(percent) => (ram !== null ? `${percent}%` : 'N/A')}
                /> */}
              </div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>SWAP Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{swap !== null ? `${Math.round(swap)}%` : 'N/A'}</div>
              <div style={{ display: 'flex', justifyContent: 'center', marginTop: '16px' }}>
                {/* <Progress
                  type="circle"
                  percent={swap !== null ? Math.round(swap) : 0}
                  size={120}
                  strokeColor={getProgressColor(swap)}
                  format={(percent) => (swap !== null ? `${percent}%` : 'N/A')}
                /> */}
              </div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>System Load</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{la}</div>
            </div>
          </Card>
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        <Col xs={24} md={12}>
          <Card title="Routes Status (Started vs Stopped)" loading={loading}>
            <div style={{ height: 260 }}>
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie data={routePieData} dataKey="value" nameKey="name" outerRadius={90} label>
                    {routePieData.map((entry, index) => (
                      <Cell key={`cell-${entry.name}`} fill={pieColors[index % pieColors.length]} />
                    ))}
                  </Pie>
                  <Tooltip />
                  <Legend />
                </PieChart>
              </ResponsiveContainer>
            </div>
          </Card>
        </Col>

        <Col xs={24} md={12}>
          <Card title="Throughput (Total)" loading={loading}>
            <Row gutter={[16, 16]}>
              <Col xs={24} sm={12}>
                <Statistic title="Inbound" value={formatBps(inBps)} />
              </Col>
              <Col xs={24} sm={12}>
                <Statistic title="Outbound" value={formatBps(outBps)} />
              </Col>
            </Row>
            <div style={{ marginTop: 12, color: 'rgba(255, 255, 255, 0.45)' }}>
              Routes with stats: {summary?.throughput?.routes_with_stats ?? 0}
            </div>
          </Card>
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        <Col xs={24} md={12}>
          <Card title="Cluster Status" loading={loading}>
            <Space direction="vertical" style={{ width: '100%' }}>
              <Statistic title="Nodes (up / down / total)" value={`${summary?.nodes?.up ?? 0} / ${summary?.nodes?.down ?? 0} / ${summary?.nodes?.total ?? 0}`} />
              <Statistic title="Enabled but not started" value={enabledNotStarted ?? 'N/A'} />
            </Space>
          </Card>
        </Col>

        <Col xs={24} md={12}>
          <Card title="Nodes" loading={loading}>
            <Table
              rowKey={(r) => r.host}
              columns={nodesColumns}
              dataSource={nodes}
              pagination={false}
              size="small"
            />
          </Card>
        </Col>
      </Row>
    </div>
  );
};

export default Dashboard; 