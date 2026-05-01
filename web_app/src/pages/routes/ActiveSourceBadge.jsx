import { Tag, Tooltip } from 'antd';

const formatSwitchMeta = (reason, timestamp) => {
  if (!reason && !timestamp) {
    return 'No switch data';
  }

  const parts = [];

  if (reason) {
    parts.push(`reason: ${reason}`);
  }

  if (timestamp) {
    parts.push(`at: ${new Date(timestamp).toLocaleString()}`);
  }

  return parts.join(' | ');
};

const ActiveSourceBadge = ({ route }) => {
  const sources = Array.isArray(route?.sources) ? route.sources : [];
  const primary = sources.find((source) => source?.position === 0);
  const activeSource = sources.find((source) => source?.id === route?.active_source_id) || primary;

  if (!activeSource) {
    return <Tag>unknown</Tag>;
  }

  const isPrimary = primary?.id === activeSource.id;

  if (isPrimary) {
    return <Tag color="green">PRIMARY</Tag>;
  }

  const sourceLabel = activeSource?.name || `#${activeSource?.position ?? '?'}`;
  const tooltipTitle = formatSwitchMeta(route?.last_switch_reason, route?.last_switch_at);

  return (
    <Tooltip title={tooltipTitle}>
      <Tag color="orange">BACKUP: {sourceLabel}</Tag>
    </Tooltip>
  );
};

export default ActiveSourceBadge;
