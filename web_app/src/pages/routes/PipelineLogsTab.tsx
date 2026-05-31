import { useCallback, useEffect, useState } from 'react';
import { Button, Checkbox, Space, Table, Tag, Tooltip, Typography } from 'antd';
import { FilterOutlined } from '@ant-design/icons';
import type { JSX } from 'react';
import dayjs from 'dayjs';
import { routesApi } from '../../utils/api';

const LIVE_WINDOW_MINUTES = 5;
const LIVE_ANALYTICS_WINDOW = 'live';
const CUSTOM_ANALYTICS_WINDOW = 'custom';

const LEVEL_COLORS: Record<string, string> = {
  ERROR: 'red',
  WARN: 'orange',
  INFO: 'blue',
  DEBUG: 'default',
  FIXME: 'purple',
  LOG: 'default',
  TRACE: 'default',
};
type LogsQueryParams = {
  limit: number;
  offset: number;
  levels?: string;
  categories?: string;
  from?: string;
  to?: string;
  window?: string;
};

type LogRow = {
  ts?: string;
  level?: string;
  category?: string;
  element?: string;
  message?: string;
};

type ColumnFilterDropdownProps = {
  routeId: string;
  column: string;
  setSelectedKeys: (keys: React.Key[]) => void;
  selectedKeys: React.Key[];
  confirm: () => void;
  clearFilters?: () => void;
};

type PipelineLogsTabProps = {
  routeId: string;
  active?: boolean;
  analyticsWindow: string;
  customRangeApplied?: Array<{ toISOString: () => string }>;
  refreshTick?: number;
  onLoadingChange?: (loading: boolean) => void;
};

const ColumnFilterDropdown = ({ routeId, column, setSelectedKeys, selectedKeys, confirm, clearFilters }: ColumnFilterDropdownProps): JSX.Element => {
  const [options, setOptions] = useState([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let active = true;
    setLoading(true);
    routesApi.getPipelineLogsDistinct(routeId, column)
      .then((result) => {
        if (active) setOptions(result?.data || []);
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => { active = false; };
  }, [routeId, column]);

  return (
    <div style={{ padding: 8, minWidth: 160 }}>
      <Checkbox.Group
        value={selectedKeys}
        onChange={setSelectedKeys}
        style={{ display: 'flex', flexDirection: 'column', gap: 6 }}
        options={loading ? [] : options.map((v) => ({ label: v, value: v }))}
      />
      {loading && <Typography.Text type="secondary" style={{ fontSize: 12 }}>Loading…</Typography.Text>}
      <Space style={{ marginTop: 8 }}>
        <Button
          type="primary"
          size="small"
          onClick={() => confirm()}
        >
          Filter
        </Button>
        <Button
          size="small"
          onClick={() => { clearFilters?.(); confirm(); }}
        >
          Reset
        </Button>
      </Space>
    </div>
  );
};

const makeFilterColumn = (routeId: string, column: string) => ({
  filterDropdown: (props: any) => (
    <ColumnFilterDropdown routeId={routeId} column={column} {...props} />
  ),
  filterIcon: (filtered: boolean) => (
    <FilterOutlined style={{ color: filtered ? '#1677ff' : undefined }} />
  ),
});

const PipelineLogsTab = ({
  routeId,
  active = true,
  analyticsWindow,
  customRangeApplied = [],
  refreshTick = 0,
  onLoadingChange,
}: PipelineLogsTabProps): JSX.Element => {
  const [logs, setLogs] = useState<LogRow[]>([]);
  const [meta, setMeta] = useState<{ total?: number } | null>(null);
  const [loading, setLoading] = useState(false);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(50);
  const [levelFilters, setLevelFilters] = useState<string[]>([]);
  const [categoryFilters, setCategoryFilters] = useState<string[]>([]);

  const fetchLogs = useCallback(async (currentPage: number, currentPageSize: number, levels: string[], categories: string[]) => {
    if (!routeId) return;

    const params: LogsQueryParams = {
      limit: currentPageSize,
      offset: (currentPage - 1) * currentPageSize,
    };

    if (levels.length > 0) params.levels = levels.join(',');
    if (categories.length > 0) params.categories = categories.join(',');

    if (analyticsWindow === LIVE_ANALYTICS_WINDOW) {
      const liveTo = dayjs();
      const liveFrom = liveTo.subtract(LIVE_WINDOW_MINUTES, 'minute');
      params.from = liveFrom.toISOString();
      params.to = liveTo.toISOString();
    } else if (analyticsWindow === CUSTOM_ANALYTICS_WINDOW) {
      const [customFrom, customTo] = customRangeApplied || [];
      if (!customFrom || !customTo) return;
      params.from = customFrom.toISOString();
      params.to = customTo.toISOString();
    } else {
      params.window = analyticsWindow;
    }

    setLoading(true);
    onLoadingChange?.(true);
    try {
      const result = await routesApi.getPipelineLogs(routeId, params);
      setLogs(result?.data?.logs || []);
      setMeta(result?.data?.meta || null);
    } finally {
      setLoading(false);
      onLoadingChange?.(false);
    }
  }, [routeId, analyticsWindow, customRangeApplied, refreshTick, onLoadingChange]);

  useEffect(() => {
    if (!active) {
      return;
    }

    setPage(1);
  }, [active, analyticsWindow, customRangeApplied, refreshTick]);

  useEffect(() => {
    if (!active) {
      return;
    }

    fetchLogs(page, pageSize, levelFilters, categoryFilters);
  }, [active, fetchLogs, page, pageSize, levelFilters, categoryFilters]);

  const handleTableChange = (pagination: any, filters: any) => {
    const newLevels = (filters.level || []) as string[];
    const newCategories = (filters.category || []) as string[];
    const newPage = pagination.current || 1;
    const newPageSize = pagination.pageSize || 50;

    setPage(newPage);
    setPageSize(newPageSize);
    setLevelFilters(newLevels);
    setCategoryFilters(newCategories);
  };

  const columns = [
    {
      title: 'Time',
      dataIndex: 'ts',
      key: 'ts',
      width: 104,
      render: (value: string | undefined) => (value ? dayjs(value).format('HH:mm:ss.SSS') : '-'),
    },
    {
      title: 'Level',
      dataIndex: 'level',
      key: 'level',
      width: 90,
      ...makeFilterColumn(routeId, 'level'),
      render: (value: string | undefined) => (
        <Tag color={LEVEL_COLORS[value ?? ''] || 'default'}>{value || '-'}</Tag>
      ),
    },
    {
      title: 'Category',
      dataIndex: 'category',
      key: 'category',
      width: 160,
      ...makeFilterColumn(routeId, 'category'),
      render: (value: string | undefined) => value || '-',
    },
    {
      title: 'Element',
      dataIndex: 'element',
      key: 'element',
      width: 120,
      render: (value: string | undefined) => value || '-',
    },
    {
      title: 'Message',
      dataIndex: 'message',
      key: 'message',
      render: (value: string | undefined) => (
        <Tooltip title={value} placement="topLeft">
          <Typography.Text ellipsis style={{ maxWidth: 500 }}>
            {value || '-'}
          </Typography.Text>
        </Tooltip>
      ),
    },
  ];

  return (
    <Table
      size="small"
      rowKey={(record: LogRow, index) => `${record.ts}-${index}`}
      loading={loading}
      dataSource={logs}
      columns={columns}
      scroll={{ x: true }}
      onChange={handleTableChange}
      pagination={{
        current: page,
        pageSize,
        total: meta?.total || 0,
        showSizeChanger: true,
        showTotal: (total: number) => `${total} logs`,
      }}
    />
  );
};

export default PipelineLogsTab;
