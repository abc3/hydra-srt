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
  Badge,
  Select,
  DatePicker,
  Alert,
  Empty
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
  ArrowLeftOutlined,
  ReloadOutlined,
  ApiOutlined,
} from '@ant-design/icons';
import { useParams, useNavigate } from 'react-router-dom';
import { routesApi, destinationsApi, sourcesApi } from '../../utils/api';
import {
  subscribeToItemSource,
  subscribeToItemStatus,
  subscribeToRouteEvents,
  subscribeToStats,
} from '../../utils/realtime';
import { ROUTES } from "../../utils/constants";
import {
  ACTIVE_ROUTE_STATUSES,
  formatStatusLabel,
  getRouteRuntimeStatus,
  isRouteBusy,
  resolvePendingRouteStatus,
} from '../../utils/routes';
import { getEndpointAddressString, renderEndpointAddress } from '../../utils/routeEndpointAddress';
import ActiveSourceBadge from './ActiveSourceBadge';
import SwitchMarkers from './SwitchMarkers';
import SourceTimeline from './SourceTimeline';
import EventsLog from './EventsLog';
import dayjs from 'dayjs';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip as RechartsTooltip,
  Legend,
  ResponsiveContainer,
  ReferenceArea,
} from 'recharts';

const { Title, Text } = Typography;
const ROUTE_ACTION_POLL_ATTEMPTS = 5;
const ROUTE_ACTION_POLL_DELAY_MS = 250;
const LIVE_ANALYTICS_WINDOW = 'live';
const DEFAULT_ANALYTICS_WINDOW = LIVE_ANALYTICS_WINDOW;
const CUSTOM_ANALYTICS_WINDOW = 'custom';
const LIVE_WINDOW_MINUTES = 5;
const ANALYTICS_COLORS = ['#1677ff', '#52c41a', '#faad14', '#722ed1', '#13c2c2', '#f5222d', '#2f54eb'];

const ANALYTICS_WINDOW_OPTIONS = [
  { label: 'live', value: LIVE_ANALYTICS_WINDOW },
  { label: 'last 30 min', value: 'last_30_min' },
  { label: 'last hour', value: 'last_hour' },
  { label: 'last 6 hour', value: 'last_6_hour' },
  { label: 'last 24 hour', value: 'last_24_hour' },
  { label: 'custom range', value: CUSTOM_ANALYTICS_WINDOW },
];

const getRuntimeStatusMeta = (status) => {
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

const renderRuntimeStatusBadge = (status) => {
  const { badgeStatus, label } = getRuntimeStatusMeta(status);
  return <Badge status={badgeStatus} text={formatStatusLabel(label).toLowerCase()} />;
};

const getEndpointValue = (endpoint, key) => endpoint?.schema_options?.[key];

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

const formatChartTimestamp = (value, includeSeconds = false) => {
  if (!value) {
    return '';
  }

  const parsed = new Date(value);

  if (Number.isNaN(parsed.getTime())) {
    return '';
  }

  const pad = (input) => String(input).padStart(2, '0');
  const hours = pad(parsed.getHours());
  const minutes = pad(parsed.getMinutes());

  if (!includeSeconds) {
    return `${hours}:${minutes}`;
  }

  const seconds = pad(parsed.getSeconds());
  return `${hours}:${minutes}:${seconds}`;
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

const toNumberOrNull = (value) => {
  if (typeof value !== 'number' || Number.isNaN(value)) {
    return null;
  }

  return value;
};

const alignToSecondIso = (date = new Date()) => {
  const aligned = new Date(date);
  aligned.setMilliseconds(0);
  return aligned.toISOString();
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
  const [analyticsWindow, setAnalyticsWindow] = useState(DEFAULT_ANALYTICS_WINDOW);
  const [customRangeDraft, setCustomRangeDraft] = useState([
    dayjs().subtract(1, 'hour'),
    dayjs(),
  ]);
  const [customRangeApplied, setCustomRangeApplied] = useState([
    dayjs().subtract(1, 'hour'),
    dayjs(),
  ]);
  const [analyticsLoading, setAnalyticsLoading] = useState(false);
  const [analyticsError, setAnalyticsError] = useState(null);
  const [analyticsData, setAnalyticsData] = useState({ points: [], meta: null });
  const [analyticsRefreshTick, setAnalyticsRefreshTick] = useState(0);
  const [eventsData, setEventsData] = useState({ events: [], meta: null });
  const [eventsLoading, setEventsLoading] = useState(false);
  const [eventsTypeFilter, setEventsTypeFilter] = useState('');
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

  useEffect(() => {
    if (!routeData?.id) {
      return undefined;
    }

    return subscribeToItemSource(routeData.id, (payload) => {
      const itemId = payload?.item_id;
      const activeSourceId = payload?.active_source_id;

      if (!itemId || itemId !== routeData.id || !activeSourceId) {
        return;
      }

      setRouteData((prev) => {
        if (!prev) {
          return prev;
        }

        return {
          ...prev,
          active_source_id: activeSourceId,
          last_switch_reason: payload?.last_switch_reason || prev.last_switch_reason,
          last_switch_at: payload?.last_switch_at || prev.last_switch_at,
        };
      });
    });
  }, [routeData?.id]);

  useEffect(() => {
    if (!routeData?.id) {
      return undefined;
    }

    return subscribeToRouteEvents(routeData.id, (payload) => {
      setEventsData((prev) => {
        const current = prev?.events || [];
        const dedupKey = `${payload?.ts}-${payload?.event_type}-${payload?.source_id || 'none'}`;
        const hasDuplicate = current.some(
          (item) => `${item?.ts}-${item?.event_type}-${item?.source_id || 'none'}` === dedupKey,
        );

        if (hasDuplicate) {
          return prev;
        }

        return {
          ...(prev || {}),
          events: [payload, ...current].slice(0, 50),
        };
      });
    });
  }, [routeData?.id]);

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

  const fetchAnalyticsData = async (queryParams) => {
    const normalizePoint = (point) => {
      const rawDestinations = point?.destinations || {};
      const normalizedDestinations = Object.entries(rawDestinations).reduce((acc, [destinationId, value]) => {
        acc[destinationId] = toNumberOrNull(value);
        return acc;
      }, {});

      return {
        timestamp: point?.timestamp,
        source: toNumberOrNull(point?.source),
        destinations: normalizedDestinations,
      };
    };

    try {
      setAnalyticsLoading(true);
      setAnalyticsError(null);
      const result = await routesApi.getAnalytics(id, queryParams);
      const nextData = result?.data || { points: [], meta: null };
      setAnalyticsData({
        ...nextData,
        points: (nextData.points || []).map(normalizePoint),
      });
    } catch (error) {
      setAnalyticsError(error.message || 'Failed to fetch analytics data');
      setAnalyticsData({ points: [], meta: null });
    } finally {
      setAnalyticsLoading(false);
    }
  };

  const fetchEventsData = async (queryParams, type = '') => {
    try {
      setEventsLoading(true);
      const result = await routesApi.getEvents(id, {
        ...queryParams,
        type: type || undefined,
        limit: 50,
        offset: 0,
      });
      setEventsData(result?.data || { events: [], meta: null });
    } catch (error) {
      setEventsData({ events: [], meta: null });
    } finally {
      setEventsLoading(false);
    }
  };

  useEffect(() => {
    if (!id) {
      return;
    }

    const queryParams = {};

    if (analyticsWindow === LIVE_ANALYTICS_WINDOW) {
      const liveTo = dayjs();
      const liveFrom = liveTo.subtract(LIVE_WINDOW_MINUTES, 'minute');
      queryParams.from = liveFrom.toISOString();
      queryParams.to = liveTo.toISOString();
    } else if (analyticsWindow === CUSTOM_ANALYTICS_WINDOW) {
      const [customFrom, customTo] = customRangeApplied;

      if (!customFrom || !customTo) {
        return;
      }

      queryParams.from = customFrom.toISOString();
      queryParams.to = customTo.toISOString();
    } else {
      queryParams.window = analyticsWindow;
    }

    fetchAnalyticsData(queryParams);
    fetchEventsData(queryParams, eventsTypeFilter);
  }, [id, analyticsWindow, customRangeApplied, analyticsRefreshTick, eventsTypeFilter]);

  useEffect(() => {
    if (!id || analyticsWindow !== LIVE_ANALYTICS_WINDOW) {
      return undefined;
    }

    return subscribeToStats((payload) => {
      if (payload?.route_id !== id || payload?.metric !== 'snapshot' || !payload?.stats) {
        return;
      }

      const snapshotTs = alignToSecondIso(new Date());
      const snapshotSource = toNumberOrNull(payload?.stats?.source?.bytes_in_per_sec);
      const snapshotDestinations = (payload?.stats?.destinations || []).reduce((acc, destination) => {
        if (!destination?.id) {
          return acc;
        }

        acc[destination.id] = toNumberOrNull(destination?.bytes_out_per_sec);
        return acc;
      }, {});
      const cutoffMs = Date.now() - (LIVE_WINDOW_MINUTES * 60 * 1000);

      setAnalyticsData((prev) => {
        const prevPoints = prev?.points || [];
        const existingIndex = prevPoints.findIndex((point) => point.timestamp === snapshotTs);
        const nextPoint = {
          timestamp: snapshotTs,
          source: snapshotSource,
          destinations: snapshotDestinations,
        };

        const mergedPoints =
          existingIndex >= 0
            ? prevPoints.map((point, index) => (index === existingIndex ? nextPoint : point))
            : [...prevPoints, nextPoint];

        const trimmedPoints = mergedPoints
          .filter((point) => {
            const pointMs = Date.parse(point.timestamp);
            return !Number.isNaN(pointMs) && pointMs >= cutoffMs;
          })
          .sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));

        return {
          ...prev,
          points: trimmedPoints,
        };
      });
    });
  }, [id, analyticsWindow]);

  const applyCustomRange = () => {
    const [customFrom, customTo] = customRangeDraft;

    if (!customFrom || !customTo) {
      messageApi.error('Please select both start and end date');
      return;
    }

    if (customFrom.valueOf() >= customTo.valueOf()) {
      messageApi.error('Start date must be earlier than end date');
      return;
    }

    setCustomRangeApplied([customFrom, customTo]);
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

  const sourceRows = (routeData?.sources || [])
    .map((source) => ({
      ...source,
      id: `source-${source.id}`,
      endpointId: source.id,
      role: source.position === 0 ? 'Primary Source' : `Backup Source #${source.position}`,
      rowType: 'source',
      name: source.name || (source.position === 0 ? 'Primary Source' : `Backup Source #${source.position}`),
      schema_status: source.status,
    }));
  const routeBusy = isRouteBusy(routeData);
  const deleteDisabledMessage = 'If you want to delete it, stop the route first';

  // Filter destinations
  const filteredDestinations = routeData?.destinations.filter(dest =>
    dest.name.toLowerCase().includes(destinationFilter.toLowerCase()) ||
    getEndpointAddressString(dest).toLowerCase().includes(destinationFilter.toLowerCase())
  ) || [];

  const endpointsData = [
    ...sourceRows,
    ...filteredDestinations.map((dest) => ({
      ...dest,
      endpointId: dest.id,
      role: 'Destination',
      rowType: 'destination',
    })),
  ];

  const destinationNameById = (routeData?.destinations || []).reduce((acc, destination) => {
    if (destination?.id) {
      acc[destination.id] = destination.name || destination.id;
    }

    return acc;
  }, {});

  const analyticsPoints = analyticsData?.points || [];
  const switches = analyticsData?.switches || [];
  const sourceTimeline = analyticsData?.source_timeline || [];
  const destinationSeriesIds = Array.from(
    new Set(
      analyticsPoints.flatMap((point) => Object.keys(point?.destinations || {}))
    )
  );

  const chartData = analyticsPoints.map((point) => {
    const destinationValues = Object.entries(point.destinations || {}).reduce((acc, [destinationId, value]) => {
      acc[`dest_${destinationId}`] = value;
      return acc;
    }, {});

    return {
      timestamp: point.timestamp,
      xLabel: formatChartTimestamp(point.timestamp, analyticsWindow === LIVE_ANALYTICS_WINDOW),
      source: point.source,
      ...destinationValues,
    };
  });

  const sourceNameById = (routeData?.sources || []).reduce((acc, source) => {
    if (source?.id) {
      acc[source.id] = source.name || `#${source.position}`;
    }

    return acc;
  }, {});
  const sourceColorById = (routeData?.sources || []).reduce((acc, source) => {
    if (!source?.id) {
      return acc;
    }

    acc[source.id] = source.position === 0 ? '#95de64' : '#ffd591';
    return acc;
  }, {});

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
      render: (_, record) => renderEndpointAddress(record),
      sorter: (a, b) => getEndpointAddressString(a).localeCompare(getEndpointAddressString(b)),
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      width: 120,
      render: (enabled, record) =>
        record.rowType === 'destination' ? (
          <Tag color={enabled ? 'success' : 'error'}>
            {enabled ? 'Yes' : 'No'}
          </Tag>
        ) : null,
      filters: [
        { text: 'Enabled', value: true },
        { text: 'Disabled', value: false },
      ],
      onFilter: (value, record) =>
        record.rowType === 'source' || record.enabled === value,
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
        { text: 'Starting', value: 'starting' },
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
          ...(record.rowType === 'source'
            ? [
                {
                  key: 'switch',
                  icon: <PlayCircleOutlined />,
                  label: 'Switch',
                  disabled: routeData?.active_source_id === record.endpointId,
                },
                {
                  key: 'test',
                  icon: <ApiOutlined />,
                  label: 'Test',
                },
              ]
            : []),
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

          if (key === 'switch') {
            handleSwitchSource(record.endpointId);
            return;
          }

          if (key === 'test') {
            handleTestSource(record.endpointId);
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

  const handleSwitchSource = async (sourceId) => {
    try {
      const result = await routesApi.switchSource(id, sourceId);
      const updatedRoute = result?.data;

      setRouteData((prev) => {
        if (!prev) {
          return prev;
        }

        if (!updatedRoute) {
          return {
            ...prev,
            active_source_id: sourceId,
            last_switch_reason: 'manual',
            last_switch_at: new Date().toISOString(),
          };
        }

        return {
          ...prev,
          ...updatedRoute,
          sources: updatedRoute.sources || prev.sources,
        };
      });

      messageApi.success('Source switched');
    } catch (error) {
      messageApi.error(`Failed to switch source: ${error.message}`);
    }
  };

  const handleTestSource = async (sourceId) => {
    try {
      await sourcesApi.test(id, sourceId);
      messageApi.success('Source test completed');
    } catch (error) {
      messageApi.error(`Failed to test source: ${error.message}`);
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

        // Update the UI to reflect that the route is starting.
        setRouteData(prev => ({
          ...prev,
          status: 'starting',
          schema_status: 'starting'
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
              <ActiveSourceBadge route={routeData} />
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
        title="Bandwidth"
        extra={(
          <Space wrap>
            <Select
              value={analyticsWindow}
              onChange={setAnalyticsWindow}
              options={ANALYTICS_WINDOW_OPTIONS}
              style={{ minWidth: 180 }}
            />
            <Button
              icon={<ReloadOutlined />}
              onClick={() => setAnalyticsRefreshTick((prev) => prev + 1)}
              loading={analyticsLoading}
              disabled={analyticsWindow === LIVE_ANALYTICS_WINDOW}
            >
              Refresh
            </Button>
            {analyticsWindow === CUSTOM_ANALYTICS_WINDOW && (
              <>
                <DatePicker
                  showTime
                  value={customRangeDraft[0]}
                  onChange={(value) => setCustomRangeDraft((prev) => [value, prev[1]])}
                  placeholder="Start time"
                />
                <DatePicker
                  showTime
                  value={customRangeDraft[1]}
                  onChange={(value) => setCustomRangeDraft((prev) => [prev[0], value])}
                  placeholder="End time"
                />
                <Button onClick={applyCustomRange}>Apply</Button>
              </>
            )}
          </Space>
        )}
      >
        <Space direction="vertical" size="middle" style={{ width: '100%' }}>
          {analyticsError && (
            <Alert type="error" showIcon message={analyticsError} />
          )}

          {!analyticsError && chartData.length === 0 && !analyticsLoading && (
            <Empty description="No analytics data for selected period" />
          )}

          <div style={{ width: '100%', height: 320 }}>
            <ResponsiveContainer>
              <LineChart data={chartData} margin={{ top: 8, right: 20, left: 28, bottom: 8 }}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="xLabel" />
                <YAxis width={88} tickMargin={8} tickFormatter={(value) => formatBitrate(value)} />
                <RechartsTooltip
                  labelFormatter={(_label, payload) => payload?.[0]?.payload?.timestamp || ''}
                  formatter={(value) => formatBitrate(value)}
                />
                <Legend />
                <Line
                  type="monotone"
                  dataKey="source"
                  name={`${routeData.name || 'Source'} in`}
                  stroke={ANALYTICS_COLORS[0]}
                  dot={false}
                  isAnimationActive={false}
                  connectNulls
                />
                {sourceTimeline.map((segment, index) => (
                  <ReferenceArea
                    key={`${segment.source_id}-${segment.from}-${index}-bg`}
                    x1={formatChartTimestamp(segment.from, analyticsWindow === LIVE_ANALYTICS_WINDOW)}
                    x2={formatChartTimestamp(segment.to, analyticsWindow === LIVE_ANALYTICS_WINDOW)}
                    y1={0}
                    y2={1}
                    ifOverflow="extendDomain"
                    fill={sourceColorById[segment.source_id] || '#d9d9d9'}
                    fillOpacity={0.08}
                    strokeOpacity={0}
                  />
                ))}
                <SwitchMarkers
                  switches={switches}
                  isLiveWindow={analyticsWindow === LIVE_ANALYTICS_WINDOW}
                  formatChartTimestamp={formatChartTimestamp}
                />
                {destinationSeriesIds.map((destinationId, index) => (
                  <Line
                    key={destinationId}
                    type="monotone"
                    dataKey={`dest_${destinationId}`}
                    name={`${destinationNameById[destinationId] || destinationId} out`}
                    stroke={ANALYTICS_COLORS[(index + 1) % ANALYTICS_COLORS.length]}
                    dot={false}
                    isAnimationActive={false}
                    connectNulls
                  />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </div>

          <SourceTimeline
            sourceTimeline={sourceTimeline}
            sourceNameById={sourceNameById}
            formatChartTimestamp={formatChartTimestamp}
          />
        </Space>
      </Card>

      <Card
        title="Events"
        extra={(
          <EventsLog.Filter value={eventsTypeFilter} onChange={setEventsTypeFilter} />
        )}
      >
        <EventsLog
          eventsLoading={eventsLoading}
          events={eventsData?.events || []}
          sourceNameById={sourceNameById}
          formatLastUpdated={formatLastUpdated}
        />
      </Card>

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
