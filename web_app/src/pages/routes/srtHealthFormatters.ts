const GBPS_THRESHOLD_MBPS = 1000;

export const srtNumeric = (value: number | null | undefined): number | null =>
  typeof value === 'number' && Number.isFinite(value) ? value : null;

export const formatSrtLinkRate = (valueMbps: number): string =>
  Math.abs(valueMbps) >= GBPS_THRESHOLD_MBPS
    ? `${(valueMbps / 1000).toFixed(2)} Gbps`
    : `${valueMbps.toFixed(2)} Mbps`;

export const formatSrtMetricDisplay = (value: number | null | undefined): string => {
  const numericValue = srtNumeric(value);
  return numericValue === null ? '—' : String(numericValue);
};
