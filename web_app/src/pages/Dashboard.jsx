import { Typography, Card, Row, Col, Statistic, Progress } from 'antd';
import { UserOutlined, ClockCircleOutlined, CheckCircleOutlined, HomeOutlined, DesktopOutlined, AreaChartOutlined, LoadingOutlined } from '@ant-design/icons';
import { useEffect, useState } from 'react';
import React from 'react';
import { nodesApi } from '../utils/api';

const { Title } = Typography;

const Dashboard = () => {
  const [nodeStats, setNodeStats] = useState({
    cpu: null,
    ram: null,
    swap: null,
    la: 'N/A / N/A / N/A'
  });
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

  // Fetch node stats for the current node
  useEffect(() => {
    const fetchNodeStats = async () => {
      try {
        setLoading(true);
        const data = await nodesApi.getAll();
        // Find the self node
        const selfNode = data.find(node => node.status === 'self');
        if (selfNode) {
          setNodeStats(selfNode);
        }
      } catch (error) {
        console.error('Error fetching node stats:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchNodeStats();
    // Set up auto-refresh every 30 seconds
    const intervalId = setInterval(fetchNodeStats, 30000);
    
    // Clean up interval on component unmount
    return () => clearInterval(intervalId);
  }, []);

  const getProgressColor = (value) => {
    if (value === null || value === undefined) return '#ccc';
    if (value > 80) return '#ff4d4f';
    if (value > 50) return '#faad14';
    return '#52c41a';
  };

  return (
    <div>
      <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Dashboard</Title>

      <Row gutter={[16, 16]}>
        <Col xs={24} sm={8}>
          <Card>
            <Statistic
              title="Active Users"
              value={112893}
              prefix={<UserOutlined />}
            />
          </Card>
        </Col>
        <Col xs={24} sm={8}>
          <Card>
            <Statistic
              title="Active Sessions"
              value={1128}
              prefix={<ClockCircleOutlined />}
            />
          </Card>
        </Col>
        <Col xs={24} sm={8}>
          <Card>
            <Statistic
              title="Tasks Completed"
              value={93}
              prefix={<CheckCircleOutlined />}
              suffix="/ 100"
            />
          </Card>
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>CPU Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.cpu !== null ? `${Math.round(nodeStats.cpu)}%` : 'N/A'}</div>
              <div style={{ display: 'flex', justifyContent: 'center', marginTop: '16px' }}>
                {/* <Progress
                  type="circle"
                  percent={nodeStats.cpu !== null ? Math.round(nodeStats.cpu) : 0}
                  size={120}
                  strokeColor={getProgressColor(nodeStats.cpu)}
                  format={(percent) => (nodeStats.cpu !== null ? `${percent}%` : 'N/A')}
                /> */}
              </div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>RAM Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.ram !== null ? `${Math.round(nodeStats.ram)}%` : 'N/A'}</div>
              <div style={{ display: 'flex', justifyContent: 'center', marginTop: '16px' }}>
                {/* <Progress
                  type="circle"
                  percent={nodeStats.ram !== null ? Math.round(nodeStats.ram) : 0}
                  size={120}
                  strokeColor={getProgressColor(nodeStats.ram)}
                  format={(percent) => (nodeStats.ram !== null ? `${percent}%` : 'N/A')}
                /> */}
              </div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>SWAP Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.swap !== null ? `${Math.round(nodeStats.swap)}%` : 'N/A'}</div>
              <div style={{ display: 'flex', justifyContent: 'center', marginTop: '16px' }}>
                {/* <Progress
                  type="circle"
                  percent={nodeStats.swap !== null ? Math.round(nodeStats.swap) : 0}
                  size={120}
                  strokeColor={getProgressColor(nodeStats.swap)}
                  format={(percent) => (nodeStats.swap !== null ? `${percent}%` : 'N/A')}
                /> */}
              </div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>System Load</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.la}</div>
            </div>
          </Card>
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        <Col xs={24} md={12}>
          <Card title="Recent Activity">
            <p>User login from 192.168.1.1</p>
            <p>System update completed</p>
            <p>New user registered</p>
          </Card>
        </Col>
        <Col xs={24} md={12}>
          <Card title="System Status">
            <p>Server Status: Online</p>
            <p>Last Backup: 2 hours ago</p>
            <p>System Load: Normal</p>
          </Card>
        </Col>
      </Row>
    </div>
  );
};

export default Dashboard; 