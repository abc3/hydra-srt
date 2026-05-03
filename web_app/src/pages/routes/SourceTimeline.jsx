import { Space, Tag, Typography } from 'antd';
import PropTypes from 'prop-types';

const { Text } = Typography;

const SourceTimeline = ({ sourceTimeline, sourceNameById, formatChartTimestamp }) => {
  if (!Array.isArray(sourceTimeline) || sourceTimeline.length === 0) {
    return null;
  }

  return (
    <Space size="small" wrap>
      <Text strong>Source Timeline:</Text>
      {sourceTimeline.map((segment, index) => (
        <Tag key={`${segment.source_id}-${segment.from}-${index}`} color="blue">
          {sourceNameById[segment.source_id] || segment.source_id}:{' '}
          {formatChartTimestamp(segment.from, true)} - {formatChartTimestamp(segment.to, true)}
        </Tag>
      ))}
    </Space>
  );
};

SourceTimeline.propTypes = {
  sourceTimeline: PropTypes.arrayOf(
    PropTypes.shape({
      source_id: PropTypes.string,
      from: PropTypes.string,
      to: PropTypes.string,
    }),
  ),
  sourceNameById: PropTypes.objectOf(PropTypes.string).isRequired,
  formatChartTimestamp: PropTypes.func.isRequired,
};

SourceTimeline.defaultProps = {
  sourceTimeline: [],
};

export default SourceTimeline;
