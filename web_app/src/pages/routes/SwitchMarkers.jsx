import PropTypes from 'prop-types';
import { ReferenceLine } from 'recharts';

const SwitchMarkers = ({ switches, isLiveWindow, formatChartTimestamp }) => {
  if (!Array.isArray(switches) || switches.length === 0) {
    return null;
  }

  return switches.map((switchEvent, index) => (
    <ReferenceLine
      key={`${switchEvent.ts}-${index}`}
      x={formatChartTimestamp(switchEvent.ts, isLiveWindow)}
      stroke="#fa8c16"
      strokeDasharray="3 3"
      label={{ value: 'switch', position: 'top', fill: '#fa8c16', fontSize: 10 }}
    />
  ));
};

SwitchMarkers.propTypes = {
  switches: PropTypes.arrayOf(
    PropTypes.shape({
      ts: PropTypes.string,
    }),
  ),
  isLiveWindow: PropTypes.bool.isRequired,
  formatChartTimestamp: PropTypes.func.isRequired,
};

SwitchMarkers.defaultProps = {
  switches: [],
};

export default SwitchMarkers;
