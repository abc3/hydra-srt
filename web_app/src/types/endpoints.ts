/** Route source/destination endpoint edit forms and API summaries. */

export type EndpointFormValues = Record<string, unknown> & {
  id?: string;
  name?: string;
  enabled?: boolean;
  node?: string;
  schema?: 'SRT' | 'UDP' | 'RTP' | string;
  mode?: 'caller' | 'listener' | 'rendezvous' | string;
  interface_sys_name?: string;
  address?: string;
  localaddress?: string;
  host?: string;
  port?: number;
  localport?: number;
  multicast?: boolean;
  multicast_iface?: string;
  bind_address_option?: string;
  latency?: number;
  authentication?: boolean;
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
