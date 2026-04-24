import { useEffect, useState } from 'react';
import { Table, Card, Button, Tag, Space, Typography, message, Modal, Dropdown, Tooltip } from 'antd';
import {
  PlusOutlined,
  EditOutlined,
  DeleteOutlined,
  ExclamationCircleFilled,
  CaretRightOutlined,
  StopOutlined,
  HomeOutlined,
  HolderOutlined,
  CheckCircleOutlined,
  ExclamationCircleOutlined,
  CopyOutlined,
} from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { routesApi } from '../../utils/api';

const { Title } = Typography;
const ONE_MINUTE_SECONDS = 60;
const ONE_HOUR_SECONDS = 60 * ONE_MINUTE_SECONDS;
const ONE_DAY_SECONDS = 24 * ONE_HOUR_SECONDS;
const ONE_MONTH_SECONDS = 30 * ONE_DAY_SECONDS;

const getStatusMeta = (status) => {
  switch ((status || '').toLowerCase()) {
    case 'processing':
    case 'started':
      return { color: 'success', label: status, icon: <CheckCircleOutlined /> };
    case 'starting':
    case 'reconnecting':
      return { color: 'processing', label: status, icon: null };
    case 'failed':
      return { color: 'error', label: status, icon: <ExclamationCircleOutlined /> };
    case 'stopped':
      return { color: 'default', label: status, icon: null };
    default:
      return { color: 'default', label: status || 'unknown', icon: null };
  }
};

const renderStatusTag = (status) => {
  const { color, label, icon } = getStatusMeta(status);

  return (
    <Tag color={color} icon={icon} variant="outlined">
      {label}
    </Tag>
  );
};

const formatUptime = (startedAt, status, nowMs) => {
  if (typeof status !== 'string' || status.toLowerCase() !== 'started' || !startedAt) {
    return '-';
  }

  const startedAtMs = new Date(startedAt).getTime();

  if (Number.isNaN(startedAtMs) || startedAtMs > nowMs) {
    return '-';
  }

  let totalSeconds = Math.floor((nowMs - startedAtMs) / 1000);

  if (totalSeconds < 0) {
    return '-';
  }

  const months = Math.floor(totalSeconds / ONE_MONTH_SECONDS);
  totalSeconds -= months * ONE_MONTH_SECONDS;

  const days = Math.floor(totalSeconds / ONE_DAY_SECONDS);
  totalSeconds -= days * ONE_DAY_SECONDS;

  const hours = Math.floor(totalSeconds / ONE_HOUR_SECONDS);
  totalSeconds -= hours * ONE_HOUR_SECONDS;

  const minutes = Math.floor(totalSeconds / ONE_MINUTE_SECONDS);
  totalSeconds -= minutes * ONE_MINUTE_SECONDS;

  const seconds = totalSeconds;

  const parts = [];

  if (months > 0) {
    parts.push(`${months}mo`);
  }

  if (days > 0) {
    parts.push(`${days}d`);
  }

  if (months === 0 && hours > 0) {
    parts.push(`${hours}h`);
  }

  if (months === 0 && days === 0 && minutes > 0) {
    parts.push(`${minutes}m`);
  }

  if (months === 0 && days === 0 && minutes === 0 && seconds > 0) {
    parts.push(`${seconds}s`);
  }

  if (parts.length === 0) {
    return '0s';
  }

  return parts.join('');
};

const formatSourceLabel = (record) => {
  const schema = record?.schema;
  const options = record?.schema_options || {};

  switch (schema) {
    case 'SRT': {
      const host = options.localaddress;
      const port = options.localport;

      if (!host || !port) {
        return 'N/A';
      }

      return `${host}:${port}`;
    }

    case 'UDP': {
      const host = options.address || options.host;
      const port = options.port;

      if (!host || !port) {
        return 'N/A';
      }

      return `${host}:${port}`;
    }

    default:
      return 'Unknown';
  }
};

const formatFullSourcePath = (record) => {
  const schema = record?.schema;
  const options = record?.schema_options || {};

  switch (schema) {
    case 'SRT': {
      const host = options.localaddress;
      const port = options.localport;

      if (!host || !port) {
        return null;
      }

      const query = options.mode ? `?mode=${options.mode}` : '';
      return `srt://${host}:${port}${query}`;
    }

    case 'UDP': {
      const host = options.address || options.host;
      const port = options.port;

      if (!host || !port) {
        return null;
      }

      return `udp://${host}:${port}`;
    }

    default:
      return null;
  }
};

const renderSrtModeTag = (mode) => {
  switch (mode) {
    case 'listener':
      return <Tag color="default">L</Tag>;
    case 'caller':
      return <Tag color="processing">C</Tag>;
    case 'rendezvous':
      return <Tag color="warning">R</Tag>;
    default:
      return null;
  }
};

const renderProtocolTag = (schema) => {
  switch (schema) {
    case 'SRT':
      return <Tag color="blue">SRT</Tag>;
    case 'UDP':
      return <Tag color="cyan">UDP</Tag>;
    default:
      return null;
  }
};

const formatLastUpdated = (date) => {
  if (!date) {
    return '-';
  }

  const parsedDate = new Date(date);

  if (Number.isNaN(parsedDate.getTime())) {
    return '-';
  }

  const pad = (value) => String(value).padStart(2, '0');

  const hours = pad(parsedDate.getHours());
  const minutes = pad(parsedDate.getMinutes());
  const seconds = pad(parsedDate.getSeconds());
  const day = pad(parsedDate.getDate());
  const month = pad(parsedDate.getMonth() + 1);
  const year = parsedDate.getFullYear();

  return `${hours}:${minutes}:${seconds} ${day}/${month}/${year}`;
};

const Routes = () => {
  const [routes, setRoutes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [nowMs, setNowMs] = useState(() => Date.now());
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const navigate = useNavigate();

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        },
        {
          href: '/routes',
          title: 'Routes',
        }
      ]);
    }
  }, []);

  useEffect(() => {
    fetchRoutes();
  }, []);

  useEffect(() => {
    const intervalId = window.setInterval(() => {
      setNowMs(Date.now());
    }, 10_000);

    return () => window.clearInterval(intervalId);
  }, []);

  const fetchRoutes = async () => {
    try {
      setLoading(true);
      const result = await routesApi.getAll();
      setRoutes(result.data);
    } catch (error) {
      messageApi.error(`Failed to fetch routes: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const showDeleteConfirm = (record) => {
    modal.confirm({
      title: 'Are you sure you want to delete this route?',
      icon: <ExclamationCircleFilled />,
      content: `Route: ${record.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return handleDelete(record.id);
      },
    });
  };

  const handleDelete = async (id) => {
    try {
      await routesApi.delete(id);
      messageApi.success('Route deleted successfully');
      fetchRoutes();
    } catch (error) {
      messageApi.error(`Failed to delete route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const handleRouteStatus = async (id, action) => {
    try {
      const result = action === 'start'
        ? await routesApi.start(id)
        : await routesApi.stop(id);

      setRoutes(routes.map(route =>
        route.id === id
          ? {
              ...route,
              status: result.data.status,
              schema_status: action === 'stop' ? 'stopped' : null,
            }
          : route
      ));

      messageApi.success(`Route ${action}ed successfully`);
    } catch (error) {
      messageApi.error(`Failed to ${action} route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const handleCopySourcePath = async (sourcePath) => {
    if (!sourcePath) {
      return;
    }

    try {
      await navigator.clipboard.writeText(sourcePath);
      messageApi.success('Source path copied');
    } catch (error) {
      messageApi.error('Failed to copy source path');
      console.error('Error:', error);
    }
  };

  const columns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      render: (text, record) => {
        return (
          <Space>
            <a href={`#/routes/${record.id}`}>
              {text}
            </a>
          </Space>
        );
      },
    },
    {
      title: 'Source',
      dataIndex: 'input',
      key: 'input',
      render: (_, record) => {
        const sourcePath = formatFullSourcePath(record);
        const srtModeTag =
          record.schema === 'SRT' ? renderSrtModeTag(record?.schema_options?.mode) : null;

        return (
          <Tooltip
            placement="topLeft"
            color="#1f1f1f"
            overlayStyle={{
              maxWidth: 'none',
              width: 'max-content',
            }}
            styles={{
              body: {
                maxWidth: 'none',
                width: 'max-content',
              },
            }}
            title={
              sourcePath ? (
                <div
                  style={{
                    display: 'inline-flex',
                    flexDirection: 'column',
                    gap: 8,
                    width: 'max-content',
                    maxWidth: 'none',
                  }}
                >
                  <span
                    style={{
                      color: 'rgba(255, 255, 255, 0.88)',
                      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
                      fontSize: 14,
                      lineHeight: 1.4,
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {sourcePath}
                  </span>
                  <Button
                    size="small"
                    icon={<CopyOutlined />}
                    onClick={(event) => {
                      event.preventDefault();
                      event.stopPropagation();
                      handleCopySourcePath(sourcePath);
                    }}
                  >
                    Copy
                  </Button>
                </div>
              ) : (
                'N/A'
              )
            }
          >
            <Space size="small">
              {renderProtocolTag(record.schema)}
              {srtModeTag}
              <span>{formatSourceLabel(record)}</span>
            </Space>
          </Tooltip>
        );
      },
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      render: (enabled) => (
        <Tag color={enabled ? 'green' : 'gray'}>
          {enabled ? 'yes' : 'no'}
        </Tag>
      ),
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
      render: (_, record) => renderStatusTag(record.schema_status || record.status),
    },
    {
      title: 'Uptime',
      key: 'uptime',
      render: (_, record) => formatUptime(record.started_at, record.status, nowMs),
    },
    {
      title: 'Updated',
      dataIndex: 'updated_at',
      key: 'updated_at',
      render: (date) => formatLastUpdated(date),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => {
        const items = [
          {
            key: 'toggle-status',
            icon: record.status === 'started' ? <StopOutlined /> : <CaretRightOutlined />,
            label: record.status === 'started' ? 'Stop' : 'Start',
          },
          {
            key: 'edit',
            icon: <EditOutlined />,
            label: 'Edit',
          },
          {
            key: 'delete',
            icon: <DeleteOutlined />,
            label: 'Delete',
            danger: true,
          },
        ];

        const handleMenuClick = ({ key }) => {
          if (key === 'toggle-status') {
            handleRouteStatus(record.id, record.status === 'started' ? 'stop' : 'start');
            return;
          }

          if (key === 'edit') {
            navigate(`/routes/${record.id}/edit`);
            return;
          }

          if (key === 'delete') {
            showDeleteConfirm(record);
          }
        };

        return (
          <Dropdown
            menu={{
              items,
              onClick: handleMenuClick,
            }}
            trigger={['click']}
          >
            <Button icon={<HolderOutlined />} />
          </Dropdown>
        );
      },
    },
  ];

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Routes</Title>
          <Space>
            <Button
              type="primary"
              icon={<PlusOutlined />}
              onClick={() => navigate('/routes/new/edit')}
            >
              Add Route
            </Button>
          </Space>
        </Space>

        <Card>
          <Table
            columns={columns}
            dataSource={routes}
            rowKey="id"
            loading={loading}
            pagination={{
              defaultPageSize: 10,
              showSizeChanger: true,
              showTotal: (total) => `Total ${total} routes`,
            }}
          />
        </Card>
      </Space>
    </div>
  );
};

export default Routes;
