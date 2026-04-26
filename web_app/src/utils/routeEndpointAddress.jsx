import { Space, Tag } from 'antd';

const getSchemaOption = (endpoint, key) => endpoint?.schema_options?.[key];

export const getEndpointAddressString = (endpoint) => {
  if (!endpoint) {
    return 'N/A';
  }

  switch (endpoint.schema) {
    case 'SRT':
      return `${getSchemaOption(endpoint, 'localaddress') || 'N/A'}:${getSchemaOption(endpoint, 'localport') || 'N/A'}`;
    case 'UDP':
      return `${getSchemaOption(endpoint, 'host') || getSchemaOption(endpoint, 'address') || 'N/A'}:${getSchemaOption(endpoint, 'port') || 'N/A'}`;
    default:
      return 'N/A';
  }
};

export const renderSrtModeTag = (mode) => {
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

export const renderProtocolTag = (schema) => {
  switch (schema) {
    case 'SRT':
      return <Tag color="blue">SRT</Tag>;
    case 'UDP':
      return <Tag color="cyan">UDP</Tag>;
    default:
      return null;
  }
};

export const renderEndpointAddress = (endpoint) => {
  if (!endpoint) {
    return <span>N/A</span>;
  }

  const srtModeTag =
    endpoint.schema === 'SRT' ? renderSrtModeTag(getSchemaOption(endpoint, 'mode')) : null;

  return (
    <Space size="small">
      {renderProtocolTag(endpoint.schema)}
      {srtModeTag}
      <span>{getEndpointAddressString(endpoint)}</span>
    </Space>
  );
};
