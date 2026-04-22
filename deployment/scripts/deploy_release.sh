#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <user@host> [release_id]" >&2
  exit 1
fi

remote_host="$1"
release_id="${2:-$(date -u +%Y%m%d%H%M%S)-$(git rev-parse --short HEAD)}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
artifact_name="hydra_srt-${release_id}.tar.gz"
artifact_path="${TMPDIR:-/tmp}/${artifact_name}"
remote_artifact="/tmp/${artifact_name}"
remote_release_dir="/opt/hydra_srt/releases/${release_id}"
releases_to_keep="${DEPLOY_RELEASES_TO_KEEP:-3}"

cleanup() {
  rm -f "$artifact_path"
}

trap cleanup EXIT

cd "$repo_root"

mix deps.get --only prod
(cd web_app && npm ci)
MIX_ENV=prod mix release

tar -C "$repo_root/_build/prod/rel" -czf "$artifact_path" hydra_srt

scp "$artifact_path" "${remote_host}:${remote_artifact}"

ssh "$remote_host" bash -s -- "$remote_artifact" "$remote_release_dir" "$releases_to_keep" <<'REMOTE'
set -euo pipefail

remote_artifact="$1"
remote_release_dir="$2"
releases_to_keep="$3"
prev_release="$(sudo readlink -f /opt/hydra_srt/current 2>/dev/null || true)"
rollback_needed=0

cleanup() {
  rm -f "$remote_artifact"
}

rollback() {
  local status=0
  if [ "$rollback_needed" -eq 1 ]; then
    if [ -n "$prev_release" ] && sudo test -d "$prev_release"; then
      echo "Deploy failed. Rolling back to $prev_release" >&2
      sudo ln -sfn "$prev_release" /opt/hydra_srt/current || status=$?
      sudo systemctl reset-failed hydra_srt 2>/dev/null || true
      sudo systemctl start hydra_srt || status=$?
      sudo systemctl --no-pager --full --lines=80 status hydra_srt >&2 || true
    else
      echo "Deploy failed. No previous release to roll back to." >&2
      sudo systemctl --no-pager --full --lines=80 status hydra_srt >&2 || true
      status=1
    fi
  fi
  return "$status"
}

fail_deploy() {
  local message="$1"
  echo "$message" >&2
  rollback
  exit 1
}

trap cleanup EXIT
trap 'rollback' ERR

sudo test -f /etc/hydra_srt/hydra_srt.env
sudo mkdir -p "$remote_release_dir"
sudo tar -xzf "$remote_artifact" -C "$remote_release_dir" --strip-components=1
sudo chown -R hydra:hydra "$remote_release_dir"

rollback_needed=1
sudo systemctl stop hydra_srt || true
sudo -u hydra "$remote_release_dir/bin/migrate"
sudo ln -sfn "$remote_release_dir" /opt/hydra_srt/current
sudo systemctl start hydra_srt

set -a
. /etc/hydra_srt/hydra_srt.env
set +a

health_port="${PORT:-4000}"
health_url="http://127.0.0.1:${health_port}/health/"

for _ in $(seq 1 24); do
  state="$(sudo systemctl is-active hydra_srt || true)"

  if [ "$state" = "active" ] && curl -fsS "$health_url" >/dev/null 2>&1; then
    rollback_needed=0
    current_release="$(basename "$(sudo readlink -f /opt/hydra_srt/current)")"
    if [ "$releases_to_keep" -gt 0 ]; then
      cd /opt/hydra_srt/releases
      ls -1dt -- */ 2>/dev/null \
        | sed 's#/$##' \
        | grep -vx "$current_release" \
        | tail -n +"$releases_to_keep" \
        | while IFS= read -r old_release; do
            [ -n "$old_release" ] || continue
            sudo rm -rf "/opt/hydra_srt/releases/$old_release" \
              || echo "Warning: could not remove old release $old_release" >&2
          done || true
    fi
    sudo systemctl --no-pager --full --lines=80 status hydra_srt
    exit 0
  fi

  if [ "$state" = "failed" ]; then
    sudo systemctl --no-pager --full --lines=80 status hydra_srt >&2 || true
    fail_deploy "hydra_srt entered failed state during deploy"
  fi

  sleep 5
done

sudo systemctl --no-pager --full --lines=80 status hydra_srt >&2 || true
fail_deploy "Timed out waiting for hydra_srt to become healthy at $health_url"
REMOTE
