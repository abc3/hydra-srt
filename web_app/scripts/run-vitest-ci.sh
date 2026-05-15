#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PER_FILE_TIMEOUT_SEC="${VITEST_FILE_TIMEOUT_SEC:-120}"
echo "Using per-file timeout: ${PER_FILE_TIMEOUT_SEC}s"

test_files=()
if command -v rg >/dev/null 2>&1; then
  while IFS= read -r line; do
    test_files+=("$line")
  done < <(rg --files src | rg "__tests__/.*\\.test\\.(js|jsx)$" | sort)
else
  while IFS= read -r line; do
    test_files+=("${line#./}")
  done < <(find ./src -type f \( -name "*.test.js" -o -name "*.test.jsx" \) | sort)
fi

if [[ ${#test_files[@]} -eq 0 ]]; then
  echo "No unit test files found"
  exit 1
fi

for test_file in "${test_files[@]}"; do
  echo ""
  echo "=== RUN ${test_file} ==="
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout "${PER_FILE_TIMEOUT_SEC}s" npx vitest run "$test_file" --pool=threads --maxWorkers=1 --reporter=default
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${PER_FILE_TIMEOUT_SEC}s" npx vitest run "$test_file" --pool=threads --maxWorkers=1 --reporter=default
  else
    perl -e 'alarm shift @ARGV; exec @ARGV' "$PER_FILE_TIMEOUT_SEC" npx vitest run "$test_file" --pool=threads --maxWorkers=1 --reporter=default
  fi
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 124 || "$exit_code" -eq 142 || "$exit_code" -eq 137 ]]; then
    echo "HANG DETECTED in ${test_file} (timed out after ${PER_FILE_TIMEOUT_SEC}s)" >&2
    exit 124
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    echo "FAILED ${test_file} (exit ${exit_code})" >&2
    exit "$exit_code"
  fi
done

echo ""
echo "All unit test files passed"
