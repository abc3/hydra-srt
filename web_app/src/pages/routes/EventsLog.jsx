import { Select, Table } from 'antd';
import PropTypes from 'prop-types';

const EventsLog = ({
  eventsLoading,
  events,
  sourceNameById,
  formatLastUpdated,
}) => {
  return (
    <Table
      size="small"
      rowKey={(record) => `${record.ts}-${record.event_type}-${record.source_id || 'none'}`}
      loading={eventsLoading}
      dataSource={events}
      pagination={{ pageSize: 10 }}
      columns={[
        { title: 'Time', dataIndex: 'ts', key: 'ts', render: (value) => formatLastUpdated(value) },
        { title: 'Type', dataIndex: 'event_type', key: 'event_type' },
        {
          title: 'Source',
          dataIndex: 'source_id',
          key: 'source_id',
          render: (value) => sourceNameById[value] || value || '-',
        },
        { title: 'Reason', dataIndex: 'reason', key: 'reason', render: (value) => value || '-' },
        { title: 'Message', dataIndex: 'message', key: 'message', render: (value) => value || '-' },
      ]}
    />
  );
};

EventsLog.Filter = function EventsLogFilter({ value, onChange }) {
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

EventsLog.propTypes = {
  eventsLoading: PropTypes.bool.isRequired,
  events: PropTypes.arrayOf(PropTypes.object),
  sourceNameById: PropTypes.objectOf(PropTypes.string).isRequired,
  formatLastUpdated: PropTypes.func.isRequired,
};

EventsLog.defaultProps = {
  events: [],
};

EventsLog.Filter.propTypes = {
  value: PropTypes.string.isRequired,
  onChange: PropTypes.func.isRequired,
};

export default EventsLog;
