import { Space, Tag, Typography } from 'antd';
import type { JSX } from 'react';
import type { TimelineSegment } from '../../types/routes';

const { Text } = Typography;

type SourceTimelineProps = {
  sourceTimeline?: TimelineSegment[];
  sourceNameById: Record<string, string>;
  formatChartTimestamp: (value: string | undefined, includeSeconds?: boolean) => string;
};

const SourceTimeline = ({ sourceTimeline = [], sourceNameById, formatChartTimestamp }: SourceTimelineProps): JSX.Element | null => {
  if (!Array.isArray(sourceTimeline) || sourceTimeline.length === 0) {
    return null;
  }

  return (
    <Space size="small" wrap>
      <Text strong>Source Timeline:</Text>
      {sourceTimeline.map((segment, index) => (
        <Tag key={`${segment.source_id}-${segment.from}-${index}`} color="blue">
          {sourceNameById[segment.source_id || ''] || segment.source_id}:{' '}
          {formatChartTimestamp(segment.from, true)} - {formatChartTimestamp(segment.to, true)}
        </Tag>
      ))}
    </Space>
  );
};

export default SourceTimeline;
