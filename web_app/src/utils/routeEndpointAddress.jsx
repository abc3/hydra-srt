import { Space, Tag } from 'antd';

const getSchemaOption = (endpoint, key) => endpoint?.schema_options?.[key];

export const getEndpointAddressString = (endpoint) => {
  if (!endpoint) {
    return 'N/A';
  }

  switch (endpoint.schema) {
    case 'SRT': {
      const mode = getSchemaOption(endpoint, 'mode');
      const address =
        mode === 'caller' || mode === 'rendezvous'
          ? getSchemaOption(endpoint, 'address') || getSchemaOption(endpoint, 'host') || getSchemaOption(endpoint, 'localaddress')
          : getSchemaOption(endpoint, 'localaddress');
      const port =
        mode === 'caller' || mode === 'rendezvous'
          ? getSchemaOption(endpoint, 'port') || getSchemaOption(endpoint, 'localport')
          : getSchemaOption(endpoint, 'localport') || getSchemaOption(endpoint, 'port');

      return `${address || 'N/A'}:${port || 'N/A'}`;
    }
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
