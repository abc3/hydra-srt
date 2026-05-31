import { ReferenceLine } from 'recharts';
import type { JSX } from 'react';
import type { SwitchEvent } from '../../types/routes';

type SwitchMarkersProps = {
  switches?: SwitchEvent[];
  isLiveWindow: boolean;
  formatChartTimestamp: (ts: string | undefined, isLiveWindow: boolean) => string;
};

const SwitchMarkers = ({ switches = [], isLiveWindow, formatChartTimestamp }: SwitchMarkersProps): JSX.Element[] | null => {
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

export default SwitchMarkers;
