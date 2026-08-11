#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || {
  echo "Run as root: sudo bash deploy/pi/retire-legacy-networking.sh" >&2
  exit 77
}

# Bridge owns local public networking after bridge-cloudflared.service is healthy.
# Retire known pre-Bridge local tunnel processes, but do not delete remote
# Cloudflare tunnels or credential files here.
legacy_units=(
  algoquest-cloudflared.service
  intqwq-cloudflared.service
)

for unit in "${legacy_units[@]}"; do
  if systemctl list-unit-files "${unit}" --no-legend 2>/dev/null | grep -q "${unit}"; then
    systemctl disable --now "${unit}" 2>/dev/null || true
    rm -f -- "/etc/systemd/system/${unit}"
    printf '[Bridge] retired legacy local tunnel unit: %s\n' "${unit}"
  fi
done

for container in algoquest-cloudflared intqwq-cloudflared; do
  if docker container inspect "${container}" >/dev/null 2>&1; then
    docker rm -f "${container}" >/dev/null
    printf '[Bridge] retired legacy local tunnel container: %s\n' "${container}"
  fi
done

systemctl daemon-reload
