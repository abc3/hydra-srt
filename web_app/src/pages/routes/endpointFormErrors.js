export const applyBackendEndpointErrors = (form, errors, basePath = []) => {
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
    'bind_port',
  ];
  const allErrorEntries = Object.entries(errors).filter(([, value]) => Array.isArray(value) && value.length > 0);
  if (allErrorEntries.length === 0) {
    return false;
  }
  const base = Array.isArray(basePath) ? basePath : [];
  const bindErrors = [
    ...(Array.isArray(errors.bind_port) ? errors.bind_port : []),
    ...(Array.isArray(errors.port) ? errors.port : []),
    ...(Array.isArray(errors.localport) ? errors.localport : []),
  ];
  const fields = [];
  const dedupeMessages = (list) => {
    const seen = new Set();
    return list.filter((message) => {
      const key = String(message);
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    });
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
