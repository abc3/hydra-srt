import { useEffect, useState } from 'react';
import { Table, Card, Button, Space, Typography, message, Modal, Tooltip, Tag } from 'antd';
import { StopOutlined, ExclamationCircleFilled, HomeOutlined } from '@ant-design/icons';
import type { ColumnsType } from 'antd/es/table';
import { systemPipelinesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';
import { subscribeToSystemPipelines } from '../../utils/realtime';
import type { RouteRecord } from '../../types/routes';

const { Title, Text } = Typography;
type PipelineRecord = {
  pid: number;
  command?: string;
  cpu?: string;
  memory?: string;
  memory_bytes?: number;
  memory_percent?: string;
  user?: string;
  start_time?: string;
  swap_bytes?: number;
  virtual_memory?: string;
  resident_memory?: string;
  cpu_time?: string;
  state?: string;
  ppid?: number;
};

type RouteNameRef = Pick<RouteRecord, 'id' | 'name'>;

declare global {
  interface Window {
    setBreadcrumbItems?: (items: any[]) => void;
  }
}

const getPipelineOwnerRoute = (command: string | undefined, routesById: Record<string, RouteNameRef>) => {
  if (!command || typeof command !== 'string') {
    return null;
  }

  const args = command.split(/\s+/).filter(Boolean);
  const routeId = args.find((arg) => routesById[arg]);

  return routeId ? routesById[routeId] : null;
};

const SystemPipelines = () => {
  const [pipelines, setPipelines] = useState<PipelineRecord[]>([]);
  const [routesById, setRoutesById] = useState<Record<string, RouteNameRef>>({});
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();

  // Set breadcrumb items for the System Pipelines page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
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
    return subscribeToSystemPipelines((payload) => {
      setPipelines(Array.isArray(payload?.pipelines) ? payload.pipelines : []);
      const routes = Array.isArray(payload?.routes) ? (payload.routes as RouteNameRef[]) : [];
      setRoutesById(
        routes.reduce((acc: Record<string, RouteNameRef>, route: RouteNameRef) => {
          acc[route.id] = route;
          return acc;
        }, {})
      );
      setLoading(false);
    });
  }, []);

  const showKillConfirm = (record: PipelineRecord) => {
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

  const handleKill = async (pid: number) => {
    try {
      await systemPipelinesApi.kill(pid);
      messageApi.success('Pipeline process killed successfully');
    } catch (error: any) {
      messageApi.error(`Failed to kill process: ${error?.message}`);
      console.error('Error:', error);
    }
  };

  const formatBytes = (bytes: number | undefined, decimals = 2): string => {
    if (!bytes) return '0 Bytes';
    if (bytes === 0) return '0 Bytes';
    
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return parseFloat((bytes / Math.pow(1024, i)).toFixed(decimals)) + ' ' + sizes[i];
  };

  const parseStartTimeAndExecPath = (startTimeValue: string | undefined) => {
    if (!startTimeValue || typeof startTimeValue !== 'string') {
      return { startTime: startTimeValue, execPath: null };
    }

    const separatorIndex = startTimeValue.indexOf(' /');
    if (separatorIndex === -1) {
      return { startTime: startTimeValue, execPath: null };
    }

    return {
      startTime: startTimeValue.slice(0, separatorIndex).trim(),
      execPath: startTimeValue.slice(separatorIndex + 1).trim(),
    };
  };

  const formatStartedAt = (startTimeValue: string | undefined) => {
    if (!startTimeValue) {
      return '-';
    }

    const parsedDate = new Date(startTimeValue);
    if (Number.isNaN(parsedDate.getTime())) {
      return startTimeValue;
    }

    const pad = (value: number) => String(value).padStart(2, '0');
    const hours = pad(parsedDate.getHours());
    const minutes = pad(parsedDate.getMinutes());
    const day = pad(parsedDate.getDate());
    const month = pad(parsedDate.getMonth() + 1);
    const year = parsedDate.getFullYear();

    return `${hours}:${minutes} ${day}/${month}/${year}`;
  };

  const columns: ColumnsType<PipelineRecord> = [
    {
      title: 'Route',
      key: 'owner',
      render: (_: unknown, record: PipelineRecord) => {
        const route = getPipelineOwnerRoute(record.command, routesById);

        if (!route) {
          return '-';
        }

        return <a href={`#/routes/${route.id}`}>{route.name || route.id}</a>;
      },
    },
    {
      title: 'PID',
      dataIndex: 'pid',
      key: 'pid',
      sorter: (a: PipelineRecord, b: PipelineRecord) => a.pid - b.pid,
    },
    {
      title: 'CPU',
      dataIndex: 'cpu',
      key: 'cpu',
      sorter: (a: PipelineRecord, b: PipelineRecord) => parseFloat(a.cpu || '0') - parseFloat(b.cpu || '0'),
      render: (text: string | undefined) => {
        const value = parseFloat(text || '0');
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
      render: (_: unknown, record: PipelineRecord) => (
        <Tooltip title={`${record.memory_bytes} bytes (${record.memory_percent})`}>
          {record.memory}
        </Tooltip>
      ),
      sorter: (a: PipelineRecord, b: PipelineRecord) => (a.memory_bytes || 0) - (b.memory_bytes || 0),
    },
    {
      title: 'User',
      dataIndex: 'user',
      key: 'user',
    },
    {
      title: 'Started At',
      dataIndex: 'start_time',
      key: 'start_time',
      render: (text: string | undefined) => formatStartedAt(parseStartTimeAndExecPath(text).startTime),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_: unknown, record: PipelineRecord) => (
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

  const expandedRowRender = (record: PipelineRecord) => {
    const { startTime, execPath } = parseStartTimeAndExecPath(record.start_time);

    const items: Array<{ label: string; value: string | number | undefined }> = [
      { label: 'PID', value: record.pid },
      { label: 'CPU Usage', value: record.cpu },
      { label: 'Memory Usage', value: `${record.memory} (${record.memory_percent})` },
      { label: 'Memory in Bytes', value: (record.memory_bytes ?? 0).toLocaleString() },
      { label: 'Swap Usage', value: formatBytes(record.swap_bytes) },
      { label: 'Swap in Bytes', value: (record.swap_bytes ?? 0).toLocaleString() },
      { label: 'User', value: record.user },
      { label: 'Started At', value: formatStartedAt(startTime) },
      { label: 'Item ID', value: record.command },
    ];

    if (execPath) {
      items.push({ label: 'Exec Path', value: execPath });
    }

    if (record.virtual_memory) {
      items.push({ label: 'Virtual Memory', value: record.virtual_memory });
      items.push({ label: 'Resident Memory', value: record.resident_memory });
      items.push({ label: 'CPU Time', value: record.cpu_time });
      items.push({ label: 'Process State', value: record.state });
      items.push({ label: 'Parent PID', value: record.ppid ?? '-' });
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
          <div>
            <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>System Pipelines</Title>
            <Text type="secondary">
              Quick live overview of the pipeline processes currently running in the system.
            </Text>
          </div>
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
