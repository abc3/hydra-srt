import { useEffect, useState } from 'react';
import {
  Card,
  Typography,
  Space,
  Tag,
  Row,
  Col,
  Button,
  Table,
  Modal,
  message,
  Input,
  Dropdown,
  Tooltip as AntTooltip,
  Badge
} from 'antd';
import {
  PlayCircleOutlined,
  PauseCircleOutlined,
  EditOutlined,
  DeleteOutlined,
  PlusOutlined,
  ExclamationCircleFilled,
  HomeOutlined,
  LoadingOutlined,
  SearchOutlined,
  HolderOutlined,
  ArrowLeftOutlined
} from '@ant-design/icons';
import { useParams, useNavigate } from 'react-router-dom';
import { routesApi, destinationsApi } from '../../utils/api';
import { subscribeToItemStatus } from '../../utils/realtime';
import { ROUTES } from "../../utils/constants";
import {
  ACTIVE_ROUTE_STATUSES,
  formatStatusLabel,
  getRouteRuntimeStatus,
  isRouteBusy,
  resolvePendingRouteStatus,
} from "../../utils/routes";

const { Title, Text } = Typography;
const ROUTE_ACTION_POLL_ATTEMPTS = 5;
const ROUTE_ACTION_POLL_DELAY_MS = 250;

const getRuntimeStatusMeta = (status) => {
  switch ((status || '').toLowerCase()) {
    case 'processing':
      return { badgeStatus: 'processing', label: 'running' };
    case 'started':
      return { badgeStatus: 'success', label: status };
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

const renderRuntimeStatusBadge = (status) => {
  const { badgeStatus, label } = getRuntimeStatusMeta(status);
  return <Badge status={badgeStatus} text={formatStatusLabel(label).toLowerCase()} />;
};

const getEndpointValue = (endpoint, key) => endpoint?.schema_options?.[key];

const getEndpointAddress = (endpoint) => {
  if (!endpoint) return 'N/A';

  switch (endpoint.schema) {
    case 'SRT':
      return `${getEndpointValue(endpoint, 'localaddress') || 'N/A'}:${getEndpointValue(endpoint, 'localport') || 'N/A'}`;
    case 'UDP':
      return `${getEndpointValue(endpoint, 'host') || getEndpointValue(endpoint, 'address') || 'N/A'}:${getEndpointValue(endpoint, 'port') || 'N/A'}`;
    default:
      return 'N/A';
  }
};

const getEndpointType = (endpoint) => {
  if (!endpoint) return 'N/A';

  if (endpoint.schema === 'SRT') {
    return getEndpointValue(endpoint, 'mode') || 'listener';
  }

  return endpoint.type || endpoint.role || endpoint.schema || 'N/A';
};

const getEndpointLatency = (endpoint) => {
  if (!endpoint) return null;
  const latency = endpoint.latency ?? getEndpointValue(endpoint, 'latency');
  return typeof latency === 'number' ? latency : null;
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

const sleep = (ms) => new Promise((resolve) => window.setTimeout(resolve, ms));

const hasRouteReachedActionResult = (route, action) => {
  const runtimeStatus = ((route?.schema_status || route?.status) || '').toLowerCase();

  if (action === 'start') {
    return ACTIVE_ROUTE_STATUSES.has(runtimeStatus);
  }

  return runtimeStatus === 'stopped' || runtimeStatus === 'failed';
};

const RouteItem = () => {
  const navigate = useNavigate();
  const { id } = useParams();
  const [routeData, setRouteData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const [destinationFilter, setDestinationFilter] = useState('');
  const [pendingAction, setPendingAction] = useState(null);
  const destinationIdsSignature = (routeData?.destinations || [])
    .map((destination) => destination?.id)
    .filter(Boolean)
    .sort()
    .join('|');

  // Breadcrumb setup
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
        },
        {
          title: loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
        }
      ]);
    }
  }, [id, routeData, loading]);

  // Fetch route data
  useEffect(() => {
    fetchRouteData();
  }, [id]);

  useEffect(() => {
    if (!routeData?.id) {
      return undefined;
    }

    const itemIds = [
      routeData.id,
      ...(routeData.destinations || []).map((destination) => destination.id).filter(Boolean),
    ];

    const uniqueItemIds = Array.from(new Set(itemIds));
    const unsubscribers = uniqueItemIds.map((itemId) =>
      subscribeToItemStatus(itemId, (payload) => {
        const itemIdFromEvent = payload?.item_id;
        const status = payload?.status;

        if (!itemIdFromEvent || typeof status !== 'string' || status.length === 0) {
          return;
        }

        setRouteData((prev) => {
          if (!prev) {
            return prev;
          }

          if (itemIdFromEvent === prev.id) {
            return {
              ...prev,
              status,
              schema_status: status,
            };
          }

          let changed = false;
          const nextDestinations = (prev.destinations || []).map((destination) => {
            if (destination.id !== itemIdFromEvent) {
              return destination;
            }

            changed = true;
            return {
              ...destination,
              status,
            };
          });

          if (!changed) {
            return prev;
          }

          return {
            ...prev,
            destinations: nextDestinations,
          };
        });
      })
    );

    return () => {
      unsubscribers.forEach((unsubscribe) => {
        unsubscribe?.();
      });
    };
  }, [routeData?.id, destinationIdsSignature]);

  const fetchRouteData = async () => {
    try {
      const result = await routesApi.getById(id);
      const route = result.data;
      setRouteData(route);

      console.log("Route data:", route);
    } catch (error) {
      messageApi.error(`Failed to fetch route data: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const fetchRouteDataSnapshot = async () => {
    const result = await routesApi.getById(id);
    return result.data;
  };

  const refreshRouteUntilStable = async (action) => {
    for (let attempt = 0; attempt < ROUTE_ACTION_POLL_ATTEMPTS; attempt += 1) {
      const nextRoute = await fetchRouteDataSnapshot();
      setRouteData((prev) => ({
        ...nextRoute,
        schema_status: resolvePendingRouteStatus(prev?.schema_status, nextRoute?.schema_status, pendingAction || action),
      }));

      if (hasRouteReachedActionResult(nextRoute, action)) {
        return true;
      }

      if (attempt < ROUTE_ACTION_POLL_ATTEMPTS - 1) {
        await sleep(ROUTE_ACTION_POLL_DELAY_MS);
      }
    }

    return false;
  };

  // Status color and button mapping
  const getStatusDetails = (routeData) => {
    // First check if routeData exists
    if (!routeData) {
      return {
        color: 'default',
        buttonColor: 'default',
        buttonIcon: <PlayCircleOutlined />,
        buttonText: 'Start',
        buttonType: 'default'
      };
    }

    const runtimeStatus = (getRouteRuntimeStatus(routeData) || '').toLowerCase();
    const canStop = ACTIVE_ROUTE_STATUSES.has(runtimeStatus);

    if (canStop) {
      return {
        color: 'success',
        buttonColor: 'default',
        buttonIcon: <PauseCircleOutlined />,
        buttonText: 'Stop',
        buttonType: 'default'
      };
    }

    return {
      color: 'error',
      buttonColor: 'primary',
      buttonIcon: <PlayCircleOutlined />,
      buttonText: 'Start',
      buttonType: 'primary'
    };
  };

  const sourceRow = routeData ? {
    ...routeData,
    id: `source-${routeData.id}`,
    endpointId: routeData.id,
    role: 'Source',
    rowType: 'source',
    name: routeData.name || 'Source',
  } : null;
  const routeBusy = isRouteBusy(routeData);
  const deleteDisabledMessage = 'If you want to delete it, stop the route first';

  // Filter destinations
  const filteredDestinations = routeData?.destinations.filter(dest =>
    dest.name.toLowerCase().includes(destinationFilter.toLowerCase()) ||
    getEndpointAddress(dest).toLowerCase().includes(destinationFilter.toLowerCase())
  ) || [];

  const endpointsData = [
    ...(sourceRow ? [sourceRow] : []),
    ...filteredDestinations.map((dest) => ({
      ...dest,
      endpointId: dest.id,
      role: 'Destination',
      rowType: 'destination',
    })),
  ];

  const endpointColumns = [
    {
      title: 'Role',
      dataIndex: 'role',
      key: 'role',
      width: 130,
      render: (role) => (
        <Tag color={role === 'Source' ? 'geekblue' : 'default'}>
          {role}
        </Tag>
      ),
      filters: [
        { text: 'Source', value: 'Source' },
        { text: 'Destination', value: 'Destination' },
      ],
      onFilter: (value, record) => record.role === value,
    },
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => a.name.localeCompare(b.name),
      render: (text, record) => (
        <Space>
          <a href={record.rowType === 'source' ? `#/routes/${id}/edit` : `#/routes/${id}/destinations/${record.endpointId}/edit`}>
            {text}
          </a>
        </Space>
      ),
    },
    {
      title: 'Addr',
      key: 'addr',
      render: (_, record) => {
        const srtModeTag =
          record.schema === 'SRT' ? renderSrtModeTag(getEndpointValue(record, 'mode')) : null;

        return (
          <Space size="small">
            {renderProtocolTag(record.schema)}
            {srtModeTag}
            <span>{getEndpointAddress(record)}</span>
          </Space>
        );
      },
      sorter: (a, b) => getEndpointAddress(a).localeCompare(getEndpointAddress(b)),
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      width: 120,
      render: (enabled) => (
        <Tag color={enabled ? 'success' : 'default'}>
          {enabled ? 'Yes' : 'No'}
        </Tag>
      ),
      filters: [
        { text: 'Enabled', value: true },
        { text: 'Disabled', value: false },
      ],
      onFilter: (value, record) => record.enabled === value,
    },
    {
      title: 'Status',
      key: 'status',
      width: 160,
      render: (_, record) => {
        const endpointStatus =
          record.rowType === 'source' ? (record.schema_status || record.status) : record.status;

        return renderRuntimeStatusBadge(endpointStatus);
      },
      filters: [
        { text: 'Started', value: 'started' },
        { text: 'Processing', value: 'processing' },
        { text: 'Reconnecting', value: 'reconnecting' },
        { text: 'Failed', value: 'failed' },
        { text: 'Stopped', value: 'stopped' },
      ],
      onFilter: (value, record) => {
        const endpointStatus =
          record.rowType === 'source' ? (record.schema_status || record.status) : record.status;

        return (endpointStatus || '').toLowerCase() === value;
      },
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => {
        const items = [
          {
            key: 'edit',
            icon: <EditOutlined />,
            label: 'Edit',
          },
          ...(record.rowType === 'destination'
            ? [{
                key: 'delete',
                icon: <DeleteOutlined />,
                label: routeBusy ? (
                  <AntTooltip title={deleteDisabledMessage}>
                    <span>Delete</span>
                  </AntTooltip>
                ) : 'Delete',
                danger: true,
                disabled: routeBusy,
              }]
            : []),
        ];

        const handleMenuClick = ({ key }) => {
          if (key === 'edit') {
            navigate(record.rowType === 'source' ? `/routes/${id}/edit` : `/routes/${id}/destinations/${record.endpointId}/edit`);
            return;
          }

          if (key === 'delete') {
            handleDeleteDestination(record);
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
            <Button
              icon={<HolderOutlined />}
              aria-label={`Actions for ${record.name}`}
            />
          </Dropdown>
        );
      },
    },
  ];

  // Delete destination handler
  const handleDeleteDestination = (record) => {
    modal.confirm({
      title: 'Are you sure you want to delete this destination?',
      icon: <ExclamationCircleFilled />,
      content: `Destination: ${record.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteDestination(record.id);
      },
    });
  };

  // Delete destination API call
  const deleteDestination = async (destId) => {
    try {
      await destinationsApi.delete(id, destId);
      messageApi.success('Destination deleted successfully');
      fetchRouteData(); // Refresh the data
    } catch (error) {
      messageApi.error(`Failed to delete destination: ${error.message}`);
      console.error('Error:', error);
    }
  };

  if (loading || !routeData) {
    return (
      <div style={{ padding: '24px' }}>
        <Card loading={true} />
      </div>
    );
  }

  // Get status details
  const statusDetails = getStatusDetails(routeData);
  const runtimeStatus = routeData?.schema_status || routeData?.status;

  // Route status toggle handler
  const handleRouteStatusToggle = async () => {
    try {
      if (routeBusy) {
        setPendingAction('stop');
        setRouteData((prev) => prev ? { ...prev, schema_status: 'stopping' } : prev);
        await routesApi.stop(id);
        const settled = await refreshRouteUntilStable('stop');
        messageApi.success('Route stopped successfully');
        if (settled === false) {
          messageApi.warning('Route is still stopping. Refresh in a moment if it does not update.');
        }
      } else {
        setPendingAction('start');
        setRouteData((prev) => prev ? { ...prev, schema_status: 'starting' } : prev);
        await routesApi.start(id);
        const settled = await refreshRouteUntilStable('start');
        messageApi.success('Route started successfully');
        if (settled === false) {
          messageApi.warning('Route is still starting. Refresh in a moment if it does not update.');
        }
      }
    } catch (error) {
      // Handle specific error cases
      if (error.message && error.message.includes('already_started')) {
        messageApi.info('Route is already started');

        // Update the UI to reflect that the route is started
        setRouteData(prev => ({
          ...prev,
          status: 'started',
          schema_status: null
        }));
      } else if (error.message && error.message.includes('not_found')) {
        messageApi.info('Route process not found. It may have already been stopped.');
        await fetchRouteData();
      } else if (error.response && error.response.status === 422) {
        // Handle 422 Unprocessable Entity error
        messageApi.error('Invalid request. The server could not process the request.');

        // Keep the current state
        console.error('422 Error:', error);
      } else {
        const action = routeBusy ? 'stop' : 'start';
        messageApi.error(`Failed to ${action} route: ${error.message}`);
      }
      console.error('Error:', error);
    } finally {
      setPendingAction(null);
    }
  };

  // Route deletion handler
  const handleRouteDelete = () => {
    modal.confirm({
      title: 'Are you sure you want to delete this route?',
      icon: <ExclamationCircleFilled />,
      content: `Route: ${routeData.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteRoute();
      },
    });
  };

  // Delete route API call
  const deleteRoute = async () => {
    try {
      await routesApi.delete(id);
      messageApi.success('Route deleted successfully');
      navigate('/routes');
    } catch (error) {
      messageApi.error(`Failed to delete route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  return (
    <Space
      direction="vertical"
      size="large"
      style={{ width: '100%', maxWidth: 1200, margin: '0 auto' }}
    >
      {contextHolder}
      {modalContextHolder}

      <Row justify="space-between" align="middle" gutter={[16, 16]}>
        <Col flex="auto">
          <Space direction="vertical" size="small" style={{ width: '100%' }}>
            <Space align="center" size="middle" wrap>
              <Button
                icon={<ArrowLeftOutlined />}
                onClick={() => navigate(ROUTES.ROUTES)}
              >
                Back
              </Button>
              <Title level={3} style={{ margin: 0, fontSize: '1.75rem', fontWeight: 600 }}>
                {routeData.name}
              </Title>
            </Space>

            <Space size="small" wrap>
              {renderRuntimeStatusBadge(runtimeStatus)}
              {routeData?.status && routeData?.schema_status && routeData.status !== routeData.schema_status && (
                <Tag color={statusDetails.color}>
                  Route {formatStatusLabel(routeData.status)}
                </Tag>
              )}
              <Text type="secondary">
                Last Updated: {new Date(routeData.updated_at).toLocaleString()}
              </Text>
            </Space>
          </Space>
        </Col>

        <Col>
          <Space wrap>
            <Button
              type={statusDetails.buttonType}
              icon={statusDetails.buttonIcon}
              onClick={handleRouteStatusToggle}
              loading={pendingAction != null}
              disabled={pendingAction != null}
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                minWidth: '80px'
              }}
            >
              {statusDetails.buttonText}
            </Button>
            <AntTooltip title={routeBusy ? deleteDisabledMessage : null}>
              <Button
                danger
                type="primary"
                icon={<DeleteOutlined />}
                onClick={handleRouteDelete}
                disabled={routeBusy || pendingAction != null}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                Delete
              </Button>
            </AntTooltip>
          </Space>
        </Col>
      </Row>

      <Card
        title="Endpoints"
        extra={
          <Button
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => navigate(`/routes/${id}/destinations/new/edit`)}
          >
            Add Destination
          </Button>
        }
      >
        <Input
          prefix={<SearchOutlined />}
          placeholder="Filter endpoints by name or address"
          style={{ marginBottom: 16, width: '100%' }}
          value={destinationFilter}
          onChange={(e) => setDestinationFilter(e.target.value)}
        />
        <Table
          columns={endpointColumns}
          dataSource={endpointsData}
          rowKey="id"
          pagination={{
            defaultPageSize: 10,
            showSizeChanger: true,
            showTotal: (total) => `Total ${total} endpoints`,
          }}
          scroll={{ x: true }}
          rowClassName={(record) => (record.rowType === 'source' ? 'route-endpoint-source-row' : '')}
        />
      </Card>
    </Space>
  );
};

export default RouteItem;
