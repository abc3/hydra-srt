import {
  CheckCircleOutlined,
  CloseCircleOutlined,
  ExclamationCircleOutlined,
  LoadingOutlined,
  WarningOutlined,
} from '@ant-design/icons';
import { Alert, Button } from 'antd';
import type { NdiCapabilities, NdiCapabilityUiState } from '../../types/ndi';
import {
  deriveNdiCapabilityUiState,
  primaryReasonCode,
  reasonCodeExplanation,
  type NdiDirection,
  collectReasonCodes,
} from './ndiCapabilityState';

type Props = {
  capabilities: NdiCapabilities | null;
  loading?: boolean;
  direction?: NdiDirection;
  onViewDiagnostics?: () => void;
};

const stateIcon = (state: NdiCapabilityUiState) => {
  switch (state) {
    case 'checking':
      return <LoadingOutlined aria-hidden />;
    case 'available':
      return <CheckCircleOutlined aria-hidden />;
    case 'feature-disabled':
    case 'plugin-missing':
    case 'runtime-missing-or-incompatible':
    case 'platform-CPU-unsupported':
      return <CloseCircleOutlined aria-hidden />;
    case 'helper-restarting':
    case 'stale':
      return <WarningOutlined aria-hidden />;
    default:
      return <ExclamationCircleOutlined aria-hidden />;
  }
};

const alertType = (state: NdiCapabilityUiState): 'info' | 'success' | 'warning' | 'error' => {
  switch (state) {
    case 'checking':
      return 'info';
    case 'available':
      return 'success';
    case 'stale':
    case 'helper-restarting':
    case 'discovery-prerequisite-unavailable':
      return 'warning';
    default:
      return 'error';
  }
};

const NdiCapabilityAlert = ({
  capabilities,
  loading = false,
  direction = 'receive',
  onViewDiagnostics,
}: Props) => {
  const state = deriveNdiCapabilityUiState(capabilities, { loading, direction });
  const reasons = collectReasonCodes(capabilities, direction);
  const primary = primaryReasonCode(reasons);

  return (
    <Alert
      type={alertType(state)}
      showIcon
      icon={stateIcon(state)}
      role="status"
      aria-live="polite"
      style={{ marginBottom: 12 }}
      message={reasonCodeExplanation(primary)}
      description={
        onViewDiagnostics && (
          <Button type="link" size="small" onClick={onViewDiagnostics} style={{ paddingInline: 0 }}>
            View diagnostics
          </Button>
        )
      }
    />
  );
};

export default NdiCapabilityAlert;
