#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"
[[ -f "${env_file}" ]] || { echo "Missing ${env_file}." >&2; exit 1; }

get_env_value() {
  local key="$1" fallback="$2" value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}

edge_port="$(get_env_value EDGE_PORT 18080)"
algoquest_domain="$(get_env_value ALGOQUEST_DOMAIN game.intqwq.com)"
intqwq_domain="$(get_env_value INTQWQ_DOMAIN intqwq.com)"

cd "${project_root}"
docker compose --env-file "${env_file}" ps

check_route() {
  local domain="$1"
  shift
  local path
  for path in "$@"; do
    curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 8 \
      -H "Host: ${domain}" "http://127.0.0.1:${edge_port}${path}" >/dev/null || return 1
  done
}

failed=0
if check_route "${algoquest_domain}" /healthz / /api/health; then
  printf 'ready <- %s (gateway, web, api)\n' "${algoquest_domain}"
else
  printf 'unavailable <- %s\n' "${algoquest_domain}" >&2
  failed=1
fi
if check_route "${intqwq_domain}" /healthz /; then
  printf 'ready <- %s (origin, page)\n' "${intqwq_domain}"
else
  printf 'unavailable <- %s\n' "${intqwq_domain}" >&2
  failed=1
fi

if command -v systemctl >/dev/null; then
  systemctl is-active bridge-edge.service 2>/dev/null || true
  systemctl is-active bridge-cloudflared.service 2>/dev/null || true
fi
exit "${failed}"
