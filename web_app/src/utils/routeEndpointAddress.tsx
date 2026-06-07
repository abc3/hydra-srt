import { Space, Tag } from 'antd';
import type { ReactNode } from 'react';
import { getEndpointOption } from '../pages/routes/endpointOptions';
import type { RouteEndpoint } from '../types/routes';

export const getEndpointAddressString = (endpoint: RouteEndpoint | null | undefined): string => {
  if (!endpoint) {
    return 'N/A';
  }

  switch (endpoint.schema) {
    case 'SRT': {
      const mode = getEndpointOption(endpoint, 'mode');
      const address =
        mode === 'caller' || mode === 'rendezvous'
          ? getEndpointOption(endpoint, 'address') || getEndpointOption(endpoint, 'host') || getEndpointOption(endpoint, 'localaddress')
          : getEndpointOption(endpoint, 'localaddress');
      const port =
        mode === 'caller' || mode === 'rendezvous'
          ? getEndpointOption(endpoint, 'port') || getEndpointOption(endpoint, 'localport')
          : getEndpointOption(endpoint, 'localport') || getEndpointOption(endpoint, 'port');

      return `${address || 'N/A'}:${port || 'N/A'}`;
    }
    case 'UDP':
      return `${getEndpointOption(endpoint, 'host') || getEndpointOption(endpoint, 'address') || 'N/A'}:${getEndpointOption(endpoint, 'port') || 'N/A'}`;
    case 'RTMP':
      return String(getEndpointOption(endpoint, 'path') || getEndpointOption(endpoint, 'location') || 'N/A');
    default:
      return 'N/A';
  }
};

export const renderSrtModeTag = (mode: string | null | undefined): ReactNode => {
  switch (mode) {
    case 'listener':
      return <Tag color="default">L</Tag>;
    case 'caller':
      return <Tag color="processing">C</Tag>;
    case 'rendezvous':
      return <Tag color="warning">R</Tag>;
    default:
      return null;
  }
};

export const renderProtocolTag = (schema: string | null | undefined): ReactNode => {
  switch (schema) {
    case 'SRT':
      return <Tag color="blue">SRT</Tag>;
    case 'UDP':
      return <Tag color="cyan">UDP</Tag>;
    case 'RTMP':
      return <Tag color="purple">RTMP</Tag>;
    default:
      return null;
  }
};

export const renderEndpointAddress = (endpoint: RouteEndpoint | null | undefined): ReactNode => {
  if (!endpoint) {
    return <span>N/A</span>;
  }

  const srtModeTag =
    endpoint.schema === 'SRT' ? renderSrtModeTag(getEndpointOption(endpoint, 'mode')) : null;

  return (
    <Space size="small">
      {renderProtocolTag(endpoint.schema)}
      {srtModeTag}
      <span>{getEndpointAddressString(endpoint)}</span>
    </Space>
  );
};
