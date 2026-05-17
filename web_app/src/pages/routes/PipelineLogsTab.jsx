import { useCallback, useEffect, useState } from 'react';
import { Button, Checkbox, Space, Table, Tag, Tooltip, Typography } from 'antd';
import { FilterOutlined } from '@ant-design/icons';
import PropTypes from 'prop-types';
import dayjs from 'dayjs';
import { routesApi } from '../../utils/api';

const LIVE_WINDOW_MINUTES = 5;
const LIVE_ANALYTICS_WINDOW = 'live';
const CUSTOM_ANALYTICS_WINDOW = 'custom';

const LEVEL_COLORS = {
  ERROR: 'red',
  WARN: 'orange',
  INFO: 'blue',
  DEBUG: 'default',
  FIXME: 'purple',
  LOG: 'default',
  TRACE: 'default',
};

const ColumnFilterDropdown = ({ routeId, column, setSelectedKeys, selectedKeys, confirm, clearFilters }) => {
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

ColumnFilterDropdown.propTypes = {
  routeId: PropTypes.string.isRequired,
  column: PropTypes.string.isRequired,
  setSelectedKeys: PropTypes.func.isRequired,
  selectedKeys: PropTypes.array.isRequired,
  confirm: PropTypes.func.isRequired,
  clearFilters: PropTypes.func,
};

ColumnFilterDropdown.defaultProps = {
  clearFilters: undefined,
};

const makeFilterColumn = (routeId, column) => ({
  filterDropdown: (props) => (
    <ColumnFilterDropdown routeId={routeId} column={column} {...props} />
  ),
  filterIcon: (filtered) => (
    <FilterOutlined style={{ color: filtered ? '#1677ff' : undefined }} />
  ),
});

const PipelineLogsTab = ({
  routeId,
  active,
  analyticsWindow,
  customRangeApplied,
  refreshTick,
  onLoadingChange,
}) => {
  const [logs, setLogs] = useState([]);
  const [meta, setMeta] = useState(null);
  const [loading, setLoading] = useState(false);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(50);
  const [levelFilters, setLevelFilters] = useState([]);
  const [categoryFilters, setCategoryFilters] = useState([]);

  const fetchLogs = useCallback(async (currentPage, currentPageSize, levels, categories) => {
    if (!routeId) return;

    const params = {
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

  const handleTableChange = (pagination, filters) => {
    const newLevels = filters.level || [];
    const newCategories = filters.category || [];
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
      render: (value) => (value ? dayjs(value).format('HH:mm:ss.SSS') : '-'),
    },
    {
      title: 'Level',
      dataIndex: 'level',
      key: 'level',
      width: 90,
      ...makeFilterColumn(routeId, 'level'),
      render: (value) => (
        <Tag color={LEVEL_COLORS[value] || 'default'}>{value || '-'}</Tag>
      ),
    },
    {
      title: 'Category',
      dataIndex: 'category',
      key: 'category',
      width: 160,
      ...makeFilterColumn(routeId, 'category'),
      render: (value) => value || '-',
    },
    {
      title: 'Element',
      dataIndex: 'element',
      key: 'element',
      width: 120,
      render: (value) => value || '-',
    },
    {
      title: 'Message',
      dataIndex: 'message',
      key: 'message',
      render: (value) => (
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
      rowKey={(record, index) => `${record.ts}-${index}`}
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
        showTotal: (total) => `${total} logs`,
      }}
    />
  );
};

PipelineLogsTab.propTypes = {
  routeId: PropTypes.string.isRequired,
  active: PropTypes.bool,
  analyticsWindow: PropTypes.string.isRequired,
  customRangeApplied: PropTypes.array,
  refreshTick: PropTypes.number,
  onLoadingChange: PropTypes.func,
};

PipelineLogsTab.defaultProps = {
  active: true,
  customRangeApplied: [],
  refreshTick: 0,
  onLoadingChange: undefined,
};

export default PipelineLogsTab;
