#!/bin/bash
set -euo pipefail

# Check if RLIMIT_NOFILE is set before using it
if [ -n "${RLIMIT_NOFILE:-}" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -n "$RLIMIT_NOFILE"
fi

# Run DB migrations automatically on container startup.
# Disable by setting RUN_MIGRATIONS=false.
if [ "${PHX_SERVER:-}" = "true" ] && [ "${RUN_MIGRATIONS:-true}" != "false" ]; then
    echo "Running database migrations..."
    /app/bin/hydra_srt eval "HydraSrt.Release.migrate"
fi

exec "$@"
