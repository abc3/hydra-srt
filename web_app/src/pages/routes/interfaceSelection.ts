import type { InterfaceOption, InterfaceRecord } from '../../types/interfaces';

export const ANY_INTERFACE_OPTION: InterfaceOption = { label: 'Any interface', value: '' };

export type InterfaceRow = {
  name?: string;
  sys_name?: string;
  ip?: string;
  enabled?: boolean;
};

export type InterfaceSelection = {
  options: InterfaceOption[];
  /** Bind IP the backend will use for each interface, CIDR suffix removed. */
  ipBySysName: Record<string, string>;
  /** Set when exactly one selectable interface has a usable address. */
  soleInterface?: string;
};

/** Mirrors `strip_cidr_suffix/1` in the backend so the UI shows the address it will bind to. */
export const stripCidrSuffix = (ip: string): string => String(ip).split('/')[0];

const LOOPBACK_NAMES = new Set(['lo', 'lo0']);

const usableIp = (ip: unknown): ip is string =>
  typeof ip === 'string' && ip !== '' && ip !== '-';

export const mergeInterfaceRows = (
  saved: InterfaceRecord[],
  system: InterfaceRecord[],
): InterfaceRow[] => {
  const savedBySysName = saved.reduce<Record<string, InterfaceRecord>>((acc, item) => {
    if (item?.sys_name) {
      acc[item.sys_name] = acc[item.sys_name] || item;
    }
    return acc;
  }, {});

  return [
    ...system
      .filter((item) => typeof item.sys_name === 'string' && item.sys_name.length > 0)
      .map((item) => {
        const sysName = item.sys_name as string;
        const aliasRecord = savedBySysName[sysName];
        return {
          name: aliasRecord?.name || '',
          sys_name: sysName,
          ip: item.ip,
          enabled: aliasRecord?.enabled ?? true,
        };
      }),
    ...saved
      .filter((item) => !system.some((systemItem) => systemItem.sys_name === item.sys_name))
      .map((item) => ({
        name: item.name,
        sys_name: item.sys_name,
        ip: item.ip,
        enabled: item.enabled ?? true,
      })),
  ];
};

export const buildInterfaceSelection = (
  saved: InterfaceRecord[],
  system: InterfaceRecord[],
): InterfaceSelection => {
  const rows = mergeInterfaceRows(saved, system).filter(
    (row) => row?.enabled !== false && row?.sys_name,
  );

  const options = rows
    .map((row) => ({
      label: `${row.name || row.sys_name} (${row.sys_name} - ${row.ip || 'N/A'})`,
      value: row.sys_name as string,
    }))
    .filter((option): option is InterfaceOption => Boolean(option.value));

  const ipBySysName = rows.reduce<Record<string, string>>((acc, row) => {
    if (row.sys_name && usableIp(row.ip)) {
      acc[row.sys_name] = stripCidrSuffix(row.ip);
    }
    return acc;
  }, {});

  // Only interfaces that can actually carry a stream count as "active" here — a box with one
  // NIC plus loopback and a pile of link-local tunnels should still pre-select the NIC.
  const addressable = rows.filter(
    (row) =>
      row.sys_name &&
      !LOOPBACK_NAMES.has(row.sys_name) &&
      usableIp(row.ip) &&
      !stripCidrSuffix(row.ip).toLowerCase().startsWith('fe80:'),
  );

  return {
    options: [ANY_INTERFACE_OPTION, ...options],
    ipBySysName,
    soleInterface: addressable.length === 1 ? (addressable[0].sys_name as string) : undefined,
  };
};
