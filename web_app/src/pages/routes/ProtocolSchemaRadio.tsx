import { Radio } from 'antd';
import type { RadioGroupProps } from 'antd';
import { listSelectableProtocols, type ProtocolDirection } from '../../utils/protocolCapabilities';

type Props = {
  direction: ProtocolDirection;
  ndiFeatureEnabled: boolean;
  disabled?: boolean;
  value?: RadioGroupProps['value'];
  onChange?: RadioGroupProps['onChange'];
};

const ProtocolSchemaRadio = ({
  direction,
  ndiFeatureEnabled,
  disabled,
  value,
  onChange,
}: Props) => {
  const protocols = listSelectableProtocols(direction, { ndiFeatureEnabled });

  return (
    <Radio.Group buttonStyle="solid" disabled={disabled} value={value} onChange={onChange}>
      {protocols.map((protocol) => (
        <Radio.Button key={protocol.schema} value={protocol.schema}>
          {protocol.label}
        </Radio.Button>
      ))}
    </Radio.Group>
  );
};

export default ProtocolSchemaRadio;
