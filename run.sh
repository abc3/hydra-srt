#!/bin/bash
set -euo pipefail

# Check if RLIMIT_NOFILE is set before using it
if [ -n "${RLIMIT_NOFILE:-}" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -n "$RLIMIT_NOFILE"
fi

exec "$@"