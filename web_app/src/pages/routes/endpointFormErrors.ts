type FieldPath = Array<string | number>;

type FieldError = {
  name: FieldPath;
  errors: string[];
};

type FormLike = {
  setFields: (fields: FieldError[]) => void;
};

type BackendErrors = Record<string, unknown>;
const isUnknownArray = (value: unknown): value is unknown[] => Array.isArray(value);

export const applyBackendEndpointErrors = (
  form: FormLike,
  errors: BackendErrors | null | undefined,
  basePath: FieldPath = [],
) => {
  if (!errors || typeof errors !== 'object') {
    return false;
  }

  const knownFieldNames = [
    'interface_sys_name',
    'address',
    'localaddress',
    'host',
    'port',
    'localport',
    'latency',
    'authentication',
    'passphrase',
    'pbkeylen',
    'multicast',
    'multicast_iface',
    'bind_address_option',
    'bind_port',
  ];
  const allErrorEntries = Object.entries(errors).filter(([, value]) => isUnknownArray(value) && value.length > 0);
  if (allErrorEntries.length === 0) {
    return false;
  }
  const base = Array.isArray(basePath) ? basePath : [];
  const bindErrors = [
    ...(isUnknownArray(errors.bind_port) ? errors.bind_port : []),
    ...(isUnknownArray(errors.port) ? errors.port : []),
    ...(isUnknownArray(errors.localport) ? errors.localport : []),
  ];
  const fields: FieldError[] = [];
  const dedupeMessages = (list: unknown[]): string[] => {
    const seen = new Set();
    return list.filter((message) => {
      const key = String(message);
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    }).map((message) => String(message));
  };

  if (bindErrors.length > 0) {
    const uniqueBindErrors = dedupeMessages(bindErrors);
    fields.push(
      { name: [...base, 'interface_sys_name'], errors: uniqueBindErrors },
      { name: [...base, 'address'], errors: uniqueBindErrors },
      { name: [...base, 'localaddress'], errors: uniqueBindErrors },
      { name: [...base, 'host'], errors: uniqueBindErrors },
      { name: [...base, 'port'], errors: uniqueBindErrors },
      { name: [...base, 'localport'], errors: uniqueBindErrors },
    );
  }

  allErrorEntries.forEach(([key, value]) => {
    if (!isUnknownArray(value)) {
      return;
    }

    if (bindErrors.length > 0 && (key === 'bind_port' || key === 'port' || key === 'localport')) {
      return;
    }

    const fieldName = key === 'bind_port' ? 'localport' : key;
    if (knownFieldNames.includes(fieldName)) {
      fields.push({ name: [...base, fieldName], errors: dedupeMessages(value) });
    }
  });

  if (fields.length === 0) {
    return false;
  }

  form.setFields(fields);

  return true;
};

export const clearEndpointBindErrors = (form: FormLike, basePath: FieldPath = []) => {
  const base = Array.isArray(basePath) ? basePath : [];
  const bindFields = ['interface_sys_name', 'address', 'localaddress', 'host', 'port', 'localport', 'multicast_iface', 'bind_address_option'];

  form.setFields(
    bindFields.map((field) => ({
      name: [...base, field],
      errors: [],
    }))
  );
};
