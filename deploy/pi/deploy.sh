#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"
example_env="${project_root}/.env.example"
wait_timeout="${BRIDGE_COMPOSE_WAIT_TIMEOUT:-120}"
allow_unhealthy="${BRIDGE_ALLOW_UNHEALTHY_ORIGINS:-0}"

die() {
  printf '[Bridge] ERROR: %s\n' "$*" >&2
  exit 1
}

get_env_value() {
  local key="$1"
  local fallback="$2"
  local value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}

[[ "${wait_timeout}" =~ ^[1-9][0-9]*$ ]] || die "BRIDGE_COMPOSE_WAIT_TIMEOUT must be a positive integer."
[[ "${allow_unhealthy}" == "0" || "${allow_unhealthy}" == "1" ]] || die "BRIDGE_ALLOW_UNHEALTHY_ORIGINS must be 0 or 1."
command -v docker >/dev/null || die "Docker is missing."
command -v curl >/dev/null || die "curl is missing."
docker info >/dev/null 2>&1 || die "Docker is not reachable."
docker compose up --help 2>&1 | grep -q -- '--wait' || die "Docker Compose must support --wait."

if [[ ! -f "${env_file}" ]]; then
  cp "${example_env}" "${env_file}"
fi
chmod 600 "${env_file}"

edge_port="$(get_env_value EDGE_PORT 8080)"
algoquest_domain="$(get_env_value ALGOQUEST_DOMAIN game.intqwq.com)"
intqwq_domain="$(get_env_value INTQWQ_DOMAIN intqwq.com)"
[[ "${edge_port}" =~ ^[0-9]+$ ]] || die "EDGE_PORT must be an integer."

cd "${project_root}"
compose=(docker compose --env-file "${env_file}")
if ! "${compose[@]}" up -d --remove-orphans --wait --wait-timeout "${wait_timeout}"; then
  "${compose[@]}" ps || true
  "${compose[@]}" logs --tail 150 edge || true
  die "The shared edge did not become healthy within ${wait_timeout}s."
fi

check_origin() {
  local domain="$1"
  shift
  local path
  for path in "$@"; do
    curl --noproxy '*' --fail --silent --show-error \
      --connect-timeout 2 --max-time 8 \
      -H "Host: ${domain}" \
      "http://127.0.0.1:${edge_port}${path}" >/dev/null || return 1
  done
}

failed=0
if check_origin "${algoquest_domain}" /healthz / /api/health; then
  printf '[Bridge] ready <- %s (gateway, web, api)\n' "${algoquest_domain}"
else
  printf '[Bridge] unavailable <- %s\n' "${algoquest_domain}" >&2
  failed=1
fi
if check_origin "${intqwq_domain}" /healthz /; then
  printf '[Bridge] ready <- %s (origin, page)\n' "${intqwq_domain}"
else
  printf '[Bridge] unavailable <- %s\n' "${intqwq_domain}" >&2
  failed=1
fi

if [[ "${failed}" == "1" && "${allow_unhealthy}" == "0" ]]; then
  "${compose[@]}" logs --tail 100 edge || true
  die "One or more origins are unavailable. Deploy both applications first."
fi

"${compose[@]}" ps
