#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

install -d -m 0755 -o hydra -g hydra /opt/hydra_srt
install -d -m 0755 -o hydra -g hydra /var/lib/hydra_srt
install -d -m 0755 -o hydra -g hydra /var/lib/hydra_srt/db
install -d -m 0755 -o hydra -g hydra /var/lib/hydra_srt/backups
install -d -m 0755 -o hydra -g hydra /var/lib/hydra_srt/releases
install -d -m 0755 -o hydra -g hydra /etc/hydra_srt

if [ ! -L /opt/hydra_srt/releases ]; then
  ln -sfn /var/lib/hydra_srt/releases /opt/hydra_srt/releases
fi

install -m 0644 "$repo_root/deployment/systemd/hydra_srt.service" /etc/systemd/system/hydra_srt.service

if [ ! -f /etc/hydra_srt/hydra_srt.env ]; then
  install -m 0640 "$repo_root/deployment/env/hydra_srt.env.example" /etc/hydra_srt/hydra_srt.env
fi

systemctl daemon-reload
systemctl enable hydra_srt

echo "Bootstrap complete."
echo "Edit /etc/hydra_srt/hydra_srt.env before the first deploy."
