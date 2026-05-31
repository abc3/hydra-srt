/** Network interface shapes (system discovery, saved aliases, UI table rows). */

export type SystemInterface = {
  id?: string;
  name?: string;
  sys_name: string;
  ip: string;
  multicast_supported?: boolean;
  raw_description?: string;
  enabled?: boolean;
};

export type InterfaceRecord = {
  id?: string;
  name?: string;
  sys_name?: string;
  ip?: string;
  enabled?: boolean;
};

export type InterfaceOption = {
  label: string;
  value: string;
};

export type InterfaceRow = {
  key: string;
  id: string | null;
  name: string;
  sys_name: string;
  ip: string;
  multicast_supported: boolean;
  raw_description: string;
  enabled: boolean;
  source: 'system' | 'custom';
};

export type InterfaceFormValues = {
  name: string;
  ip: string;
  sys_name: string;
  enabled?: boolean;
  sys_name_selector?: string;
};

export type InterfacePrefill = {
  sys_name: string;
  ip: string;
  multicast_supported: boolean;
};
