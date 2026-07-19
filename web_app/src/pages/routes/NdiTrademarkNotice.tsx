import { Typography } from 'antd';
import { NDI_TRADEMARK_NOTICE, NDI_VIDEO_URL } from './ndiConstants';

const { Text, Link } = Typography;

type Props = {
  id?: string;
};

/** Required NDI trademark notice + nearby ndi.video link (never a pre-checked checkbox). */
const NdiTrademarkNotice = ({ id }: Props) => (
  <Text type="secondary" id={id} style={{ display: 'block', marginTop: 8 }}>
    {NDI_TRADEMARK_NOTICE}{' '}
    <Link href={NDI_VIDEO_URL} target="_blank" rel="noreferrer">
      ndi.video
    </Link>
  </Text>
);

export default NdiTrademarkNotice;
