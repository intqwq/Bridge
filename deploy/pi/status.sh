#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"
[[ -f "${env_file}" ]] || { echo "Missing ${env_file}." >&2; exit 1; }

get_env() {
  local key="$1" fallback="$2" value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}
edge_port="$(get_env EDGE_PORT 18080)"
state_dir="$(get_env BRIDGE_STATE_DIR /var/lib/intqwq-bridge)"

cd "${project_root}"
docker compose --env-file "${env_file}" ps

failed=0
if curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 8 \
  "http://127.0.0.1:${edge_port}/healthz" >/dev/null; then
  printf '[Bridge] edge healthy <- 127.0.0.1:%s\n' "${edge_port}"
else
  printf '[Bridge] edge unavailable <- 127.0.0.1:%s\n' "${edge_port}" >&2
  failed=1
fi

if command -v systemctl >/dev/null; then
  printf '[Bridge] bridge-edge.service: %s\n' "$(systemctl is-active bridge-edge.service 2>/dev/null || true)"
  printf '[Bridge] bridge-cloudflared.service: %s\n' "$(systemctl is-active bridge-cloudflared.service 2>/dev/null || true)"
fi

printf '\n[Bridge] registered routes\n'
if command -v bridge >/dev/null 2>&1; then
  bridge list || true
elif [[ -d "${state_dir}/registry" ]]; then
  find "${state_dir}/registry" -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort
fi

exit "${failed}"
