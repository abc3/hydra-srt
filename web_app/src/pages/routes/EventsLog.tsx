import { Select, Table } from 'antd';
import type { JSX } from 'react';
import type { ColumnsType } from 'antd/es/table';

type EventRow = {
  ts?: string;
  event_type?: string;
  source_id?: string;
  reason?: string;
  message?: string;
};

type EventsLogProps = {
  eventsLoading: boolean;
  events?: EventRow[];
  sourceNameById: Record<string, string>;
  formatLastUpdated: (value: string | undefined) => string;
};

type EventsLogFilterProps = {
  value: string;
  onChange: (value: string) => void;
};

const EventsLog = ({
  eventsLoading,
  events = [],
  sourceNameById,
  formatLastUpdated,
}: EventsLogProps): JSX.Element => {
  const columns: ColumnsType<EventRow> = [
    { title: 'Time', dataIndex: 'ts', key: 'ts', render: (value: string | undefined) => formatLastUpdated(value) },
    { title: 'Type', dataIndex: 'event_type', key: 'event_type' },
    {
      title: 'Source',
      dataIndex: 'source_id',
      key: 'source_id',
      render: (value: string | undefined) => sourceNameById[value || ''] || value || '-',
    },
    { title: 'Reason', dataIndex: 'reason', key: 'reason', render: (value: string | undefined) => value || '-' },
    { title: 'Message', dataIndex: 'message', key: 'message', render: (value: string | undefined) => value || '-' },
  ];

  return (
    <Table
      size="small"
      rowKey={(record: EventRow) => `${record.ts}-${record.event_type}-${record.source_id || 'none'}`}
      loading={eventsLoading}
      dataSource={events}
      pagination={{ pageSize: 10 }}
      columns={columns}
    />
  );
};

EventsLog.Filter = function EventsLogFilter({ value, onChange }: EventsLogFilterProps): JSX.Element {
  return (
    <Select
      value={value}
      onChange={onChange}
      style={{ minWidth: 180 }}
      options={[
        { label: 'all', value: '' },
        { label: 'source_switch', value: 'source_switch' },
        { label: 'pipeline_failed', value: 'pipeline_failed' },
        { label: 'pipeline_reconnecting', value: 'pipeline_reconnecting' },
      ]}
    />
  );
};

export default EventsLog;
