#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo bash deploy/pi/install-systemd.sh" >&2; exit 77; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"
unit_path="${BRIDGE_SYSTEMD_UNIT_PATH:-/etc/systemd/system/bridge-edge.service}"
wait_timeout="${BRIDGE_COMPOSE_WAIT_TIMEOUT:-120}"
dry_run="${BRIDGE_SYSTEMD_DRY_RUN:-0}"

[[ -f "${env_file}" ]] || { echo "Missing ${env_file}. Run install-cli.sh and deploy.sh first." >&2; exit 1; }
[[ "${project_root}" != *[[:space:]\\\"]* ]] || { echo "Bridge path cannot contain whitespace, backslashes, or quotes." >&2; exit 1; }
[[ "${wait_timeout}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid wait timeout." >&2; exit 1; }
docker_path="$(command -v docker)"

cat > "${unit_path}" <<SYSTEMD_UNIT
[Unit]
Description=Bridge neutral ingress edge
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${project_root}
ExecStartPre=/bin/bash ${project_root}/deploy/pi/check-network-boundary.sh
ExecStart=${docker_path} compose --env-file ${env_file} up -d --remove-orphans --wait --wait-timeout ${wait_timeout}
ExecStop=${docker_path} compose --env-file ${env_file} down --remove-orphans
TimeoutStartSec=$((wait_timeout + 30))
TimeoutStopSec=60
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SYSTEMD_UNIT

systemd-analyze verify "${unit_path}"
if [[ "${dry_run}" == "1" ]]; then
  echo "[Bridge] Verified ${unit_path}."
  exit 0
fi
systemctl daemon-reload
systemctl enable bridge-edge.service
systemctl reset-failed bridge-edge.service 2>/dev/null || true
systemctl restart bridge-edge.service
