import { useEffect, useState } from 'react';
import { Table, Card, Button, Tag, Space, Typography, message, Modal, Dropdown, Tooltip, Input, Badge, Drawer, Tree, Empty } from 'antd';
import {
  PlusOutlined,
  EditOutlined,
  DeleteOutlined,
  ExclamationCircleFilled,
  CaretRightOutlined,
  StopOutlined,
  HomeOutlined,
  HolderOutlined,
  SearchOutlined,
  BarChartOutlined,
  DownOutlined,
} from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { routesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';
import { subscribeToItemStatus, subscribeToStats } from '../../utils/realtime';
import {
  ACTIVE_ROUTE_STATUSES,
  compareUptime,
  formatStatusLabel,
  getRouteRuntimeStatus,
  isRouteBusy,
} from '../../utils/routes';
import { getEndpointAddressString, renderEndpointAddress } from '../../utils/routeEndpointAddress';

const { Title, Text } = Typography;
const ONE_MINUTE_SECONDS = 60;
const ONE_HOUR_SECONDS = 60 * ONE_MINUTE_SECONDS;
const ONE_DAY_SECONDS = 24 * ONE_HOUR_SECONDS;
const ONE_MONTH_SECONDS = 30 * ONE_DAY_SECONDS;
const DELETE_DISABLED_MESSAGE = 'If you want to delete it, stop the route first';
const ROUTE_THROUGHPUT_STATUSES = new Set(['started', 'processing']);
const ROUTE_ACTION_POLL_ATTEMPTS = 5;
const ROUTE_ACTION_POLL_DELAY_MS = 250;

const getStatusMeta = (status) => {
  switch ((status || '').toLowerCase()) {
    case 'processing':
      return { badgeStatus: 'success', label: 'running' };
    case 'started':
      return { badgeStatus: 'processing', label: 'starting' };
    case 'starting':
    case 'stopping':
    case 'reconnecting':
      return { badgeStatus: 'processing', label: status };
    case 'failed':
      return { badgeStatus: 'error', label: status };
    case 'stopped':
      return { badgeStatus: 'error', label: status };
    default:
      return { badgeStatus: 'default', label: status || 'unknown' };
  }
};

const renderStatusBadge = (status) => {
  const { badgeStatus, label } = getStatusMeta(status);
  return <Badge status={badgeStatus} text={formatStatusLabel(label).toLowerCase()} />;
};

const sleep = (ms) => new Promise((resolve) => window.setTimeout(resolve, ms));

const hasRouteReachedActionResult = (route, action) => {
  const runtimeStatus = (getRouteRuntimeStatus(route) || '').toLowerCase();

  if (action === 'start') {
    return ACTIVE_ROUTE_STATUSES.has(runtimeStatus);
  }

  return runtimeStatus === 'stopped' || runtimeStatus === 'failed';
};

const formatUptime = (startedAt, status, nowMs) => {
  if (
    typeof status !== 'string' ||
    !ACTIVE_ROUTE_STATUSES.has(status.toLowerCase()) ||
    !startedAt
  ) {
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

const formatBitrate = (bytesPerSecond) => {
  if (typeof bytesPerSecond !== 'number' || Number.isNaN(bytesPerSecond)) {
    return '-';
  }

  const bitsPerSecond = bytesPerSecond * 8;
  const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  let value = bitsPerSecond;
  let unitIndex = 0;

  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }

  const digits = value >= 100 || unitIndex === 0 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(digits)} ${units[unitIndex]}`;
};

const formatStatsValue = (value) => {
  if (value === null) {
    return 'null';
  }

  if (value === undefined) {
    return 'undefined';
  }

  if (typeof value === 'string') {
    return value;
  }

  return String(value);
};

const buildStatsTreeData = (value, path = 'stats', label = 'stats') => {
  if (Array.isArray(value)) {
    return {
      title: `${label} [${value.length}]`,
      key: path,
      children: value.map((item, index) => buildStatsTreeData(item, `${path}.${index}`, `[${index}]`)),
    };
  }

  if (value && typeof value === 'object') {
    const entries = Object.entries(value);

    return {
      title: `${label} {${entries.length}}`,
      key: path,
      children: entries.map(([key, childValue]) => buildStatsTreeData(childValue, `${path}.${key}`, key)),
    };
  }

  return {
    title: (
      <span>
        <Text>{label}: </Text>
        <Text code>{formatStatsValue(value)}</Text>
      </span>
    ),
    key: path,
  };
};

const collectTreeKeys = (nodes) => {
  const keys = [];

  nodes.forEach((node) => {
    keys.push(node.key);

    if (node.children?.length) {
      keys.push(...collectTreeKeys(node.children));
    }
  });

  return keys;
};

const Routes = () => {
  const [routes, setRoutes] = useState([]);
  const [routesFilter, setRoutesFilter] = useState('');
  const [routeStats, setRouteStats] = useState({});
  const [statsDrawerRouteId, setStatsDrawerRouteId] = useState(null);
  const [loading, setLoading] = useState(true);
  const [nowMs, setNowMs] = useState(() => Date.now());
  const [pendingRouteActions, setPendingRouteActions] = useState({});
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const navigate = useNavigate();
  const routeIdsSignature = routes
    .map((route) => route?.id)
    .filter(Boolean)
    .sort()
    .join('|');

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.ROUTES,
          title: 'Routes',
        }
      ]);
    }
  }, []);

  useEffect(() => {
    fetchRoutes();
  }, []);

  useEffect(() => {
    return subscribeToStats((payload) => {
      setRouteStats((prev) => {
        const routeId = payload?.route_id;
        const value = payload?.value;

        if (!routeId) {
          return prev;
        }

        const current = prev[routeId] || { outByDestination: {} };

        if (payload.metric === 'snapshot' && payload.stats && typeof payload.stats === 'object') {
          return {
            ...prev,
            [routeId]: {
              ...current,
              snapshot: payload.stats,
              outByDestination: current.outByDestination || {},
            },
          };
        }

        if (typeof value !== 'number') {
          return prev;
        }

        if (payload.direction === 'in') {
          return {
            ...prev,
            [routeId]: {
              ...current,
              in: value,
              outByDestination: current.outByDestination || {},
            },
          };
        }

        if (payload.direction === 'out' && payload.destination_id) {
          return {
            ...prev,
            [routeId]: {
              ...current,
              outByDestination: {
                ...(current.outByDestination || {}),
                [payload.destination_id]: value,
              },
            },
          };
        }

        return prev;
      });
    });
  }, []);

  useEffect(() => {
    const routeIds = routeIdsSignature ? routeIdsSignature.split('|') : [];

    if (routeIds.length === 0) {
      return undefined;
    }

    const unsubscribers = routeIds.map((routeId) =>
      subscribeToItemStatus(routeId, (payload) => {
        const itemId = payload?.item_id;
        const status = payload?.status;

        if (!itemId || typeof status !== 'string' || status.length === 0) {
          return;
        }

        setRoutes((prev) =>
          prev.map((route) =>
            route.id === itemId
              ? {
                  ...route,
                  status,
                  schema_status: status,
                }
              : route
          )
        );
      })
    );

    return () => {
      unsubscribers.forEach((unsubscribe) => unsubscribe());
    };
  }, [routeIdsSignature]);

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

  const fetchRoutesData = async () => {
    const result = await routesApi.getAll();
    return result.data;
  };

  const refreshRoutesUntilStable = async (routeId, action) => {
    for (let attempt = 0; attempt < ROUTE_ACTION_POLL_ATTEMPTS; attempt += 1) {
      const nextRoutes = await fetchRoutesData();
      setRoutes(nextRoutes);

      const nextRoute = nextRoutes.find((route) => route.id === routeId);
      if (!nextRoute || hasRouteReachedActionResult(nextRoute, action)) {
        return true;
      }

      if (attempt < ROUTE_ACTION_POLL_ATTEMPTS - 1) {
        await sleep(ROUTE_ACTION_POLL_DELAY_MS);
      }
    }

    return false;
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
      setPendingRouteActions((prev) => ({ ...prev, [id]: action }));
      setRoutes((prev) => prev.map((route) => (
        route.id === id
          ? {
              ...route,
              schema_status: action === 'start' ? 'starting' : 'stopping',
            }
          : route
      )));

      await (action === 'start' ? routesApi.start(id) : routesApi.stop(id));
      const settled = await refreshRoutesUntilStable(id, action);

      messageApi.success(`Route ${action}ed successfully`);
      if (settled === false) {
        messageApi.warning(`Route is still ${action === 'start' ? 'starting' : 'stopping'}. Refresh in a moment if it does not update.`);
      }
    } catch (error) {
      await fetchRoutes();
      messageApi.error(`Failed to ${action} route: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setPendingRouteActions((prev) => {
        const next = { ...prev };
        delete next[id];
        return next;
      });
    }
  };

  const getNameColumnSearchProps = () => ({
    filterDropdown: ({ setSelectedKeys, selectedKeys, confirm, clearFilters }) => (
      <div style={{ padding: 8 }}>
        <Input
          placeholder="Search name"
          value={selectedKeys[0]}
          onChange={(event) => {
            const value = event.target.value;
            setSelectedKeys(value ? [value] : []);
          }}
          onPressEnter={() => confirm()}
          style={{ marginBottom: 8, display: 'block', width: 200 }}
        />
        <Space>
          <Button
            type="primary"
            icon={<SearchOutlined />}
            size="small"
            onClick={() => confirm()}
          >
            Search
          </Button>
          <Button
            size="small"
            onClick={() => {
              clearFilters?.();
              confirm();
            }}
          >
            Reset
          </Button>
        </Space>
      </div>
    ),
    filterIcon: (filtered) => <SearchOutlined style={{ color: filtered ? '#1677ff' : undefined }} />,
    onFilter: (value, record) => (record.name || '').toLowerCase().includes(String(value).toLowerCase()),
  });

  const columns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => (a.name || '').localeCompare(b.name || ''),
      ...getNameColumnSearchProps(),
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
      title: 'Source Addr',
      key: 'addr',
      render: (_, record) => renderEndpointAddress(record),
      sorter: (a, b) => getEndpointAddressString(a).localeCompare(getEndpointAddressString(b)),
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      filters: [
        { text: 'Enabled', value: true },
        { text: 'Disabled', value: false },
      ],
      onFilter: (value, record) => record.enabled === value,
      render: (enabled) => (
        <Tag color={enabled ? 'green' : 'error'}>
          {enabled ? 'Yes' : 'No'}
        </Tag>
      ),
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
      filters: [
        { text: 'Starting', value: 'starting' },
        { text: 'Processing', value: 'processing' },
        { text: 'Reconnecting', value: 'reconnecting' },
        { text: 'Failed', value: 'failed' },
        { text: 'Stopped', value: 'stopped' },
      ],
      onFilter: (value, record) => (getRouteRuntimeStatus(record) || '').toLowerCase() === value,
      render: (_, record) => renderStatusBadge(getRouteRuntimeStatus(record)),
    },
    {
      title: 'In / Out',
      key: 'throughput',
      render: (_, record) => {
        const runtime = (getRouteRuntimeStatus(record) || '').toLowerCase();

        if (!ROUTE_THROUGHPUT_STATUSES.has(runtime)) {
          return <span>- / -</span>;
        }

        const stats = routeStats[record.id] || {};
        const outValues = Object.values(stats.outByDestination || {})
          .filter((value) => typeof value === 'number' && !Number.isNaN(value));
        const out = outValues.length > 0
          ? outValues.reduce((sum, value) => sum + value, 0)
          : null;

        return (
          <span>
            {formatBitrate(stats.in)} / {formatBitrate(out)}
          </span>
        );
      },
    },
    {
      title: 'Uptime',
      key: 'uptime',
      sorter: (a, b, sortOrder) => compareUptime(a, b, sortOrder, nowMs),
      render: (_, record) => formatUptime(record.started_at, getRouteRuntimeStatus(record), nowMs),
    },
    {
      title: 'Stats',
      key: 'stats',
      align: 'center',
      render: (_, record) => (
        <Tooltip title="Stats">
          <Button
            icon={<BarChartOutlined />}
            onClick={() => setStatsDrawerRouteId(record.id)}
          />
        </Tooltip>
      ),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => {
        const pendingAction = pendingRouteActions[record.id];
        const routeBusy = isRouteBusy(record);
        const runtimeStatus = getRouteRuntimeStatus(record);
        const runtimeStatusLower = (runtimeStatus || '').toLowerCase();
        const canStart = runtimeStatusLower === 'stopped';
        const routeAction = canStart ? 'start' : 'stop';
        const actionsDisabled = !!pendingAction;
        const items = [
          {
            key: 'toggle-status',
            icon: canStart ? <CaretRightOutlined /> : <StopOutlined />,
            label: canStart ? 'Start' : 'Stop',
            disabled: actionsDisabled,
          },
          {
            key: 'edit',
            icon: <EditOutlined />,
            label: 'Edit',
          },
          {
            key: 'delete',
            icon: <DeleteOutlined />,
            label: routeBusy ? (
              <Tooltip title={DELETE_DISABLED_MESSAGE}>
                <span>Delete</span>
              </Tooltip>
            ) : 'Delete',
            danger: true,
            disabled: routeBusy || !!pendingAction,
          },
        ];

        const handleMenuClick = ({ key }) => {
          if (key === 'toggle-status') {
            handleRouteStatus(record.id, routeAction);
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
            <Button aria-label={`Route actions for ${record.name || record.id}`} icon={<HolderOutlined />} />
          </Dropdown>
        );
      },
    },
  ];

  const normalizedRoutesFilter = routesFilter.trim().toLowerCase();
  const filteredRoutes = normalizedRoutesFilter
    ? routes.filter((route) => {
        const routeName = (route.name || '').toLowerCase();
        const routeAddress = getEndpointAddressString(route).toLowerCase();
        return routeName.includes(normalizedRoutesFilter) || routeAddress.includes(normalizedRoutesFilter);
      })
    : routes;
  const statsDrawerRoute = routes.find((route) => route.id === statsDrawerRouteId);
  const statsSnapshot = statsDrawerRouteId ? routeStats[statsDrawerRouteId]?.snapshot : null;
  const statsTreeData = statsSnapshot ? [buildStatsTreeData(statsSnapshot)] : [];
  const expandedStatsKeys = collectTreeKeys(statsTreeData);

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
          <Input
            prefix={<SearchOutlined />}
            placeholder="Filter routes by name or address"
            style={{ marginBottom: 16, width: '100%' }}
            value={routesFilter}
            onChange={(event) => setRoutesFilter(event.target.value)}
          />
          <Table
            columns={columns}
            dataSource={filteredRoutes}
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
      <Drawer
        title={`Stats${statsDrawerRoute?.name ? `: ${statsDrawerRoute.name}` : ''}`}
        open={!!statsDrawerRouteId}
        onClose={() => setStatsDrawerRouteId(null)}
        width={640}
      >
        {statsTreeData.length > 0 ? (
          <Tree
            showLine
            switcherIcon={<DownOutlined />}
            expandedKeys={expandedStatsKeys}
            treeData={statsTreeData}
          />
        ) : (
          <Empty description="No stats received yet" />
        )}
      </Drawer>
    </div>
  );
};

export default Routes;
