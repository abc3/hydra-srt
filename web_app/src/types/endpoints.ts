/** Route source/destination endpoint edit forms and API summaries. */

import type { NdiEndpointFields } from './ndi';
import type { YoutubeEndpointFields } from './youtube';

export type EndpointFormValues = Record<string, unknown> & NdiEndpointFields & YoutubeEndpointFields & {
  id?: string;
  name?: string;
  enabled?: boolean;
  node?: string;
  schema?: 'SRT' | 'UDP' | 'RTP' | 'RTMP' | 'NDI' | 'YOUTUBE' | string;
  mode?: 'caller' | 'listener' | 'rendezvous' | string;
  interface_sys_name?: string;
  address?: string;
  localaddress?: string;
  host?: string;
  port?: number;
  localport?: number;
  program_number?: number | null;
  multicast?: boolean;
  multicast_iface?: string;
  bind_address_option?: string;
  path?: string;
  location?: string;
  latency?: number;
  authentication?: boolean;
  streamid?: string;
  passphrase?: string;
  pbkeylen?: number;
};

export type RouteSummary = {
  id?: string;
  name?: string;
};

export type RouteSourceEndpointEditProps = {
  initialValues?: Partial<EndpointFormValues>;
  onChange?: (values: EndpointFormValues) => void;
};

export type RouteDestEditProps = {
  initialValues?: Partial<EndpointFormValues>;
  onChange?: (values: EndpointFormValues) => void;
};
