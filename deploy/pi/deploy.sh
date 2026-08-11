#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"
example_env="${project_root}/.env.example"
wait_timeout="${BRIDGE_COMPOSE_WAIT_TIMEOUT:-120}"

die() { printf '[Bridge] ERROR: %s\n' "$*" >&2; exit 1; }
get_env() {
  local key="$1" fallback="$2" value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}

[[ "${wait_timeout}" =~ ^[1-9][0-9]*$ ]] || die "BRIDGE_COMPOSE_WAIT_TIMEOUT must be a positive integer."
command -v docker >/dev/null || die "Docker is missing."
command -v curl >/dev/null || die "curl is missing."
docker info >/dev/null 2>&1 || die "Docker is not reachable."
docker compose up --help 2>&1 | grep -q -- '--wait' || die "Docker Compose must support --wait."

[[ -f "${env_file}" ]] || cp "${example_env}" "${env_file}"
chmod 600 "${env_file}"
bash "${script_dir}/check-network-boundary.sh"

edge_port="$(get_env EDGE_PORT 18080)"
cd "${project_root}"
compose=(docker compose --env-file "${env_file}")
if ! "${compose[@]}" up -d --remove-orphans --wait --wait-timeout "${wait_timeout}"; then
  "${compose[@]}" ps || true
  "${compose[@]}" logs --tail 150 edge || true
  die "Bridge edge did not become healthy within ${wait_timeout}s."
fi

curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 8 \
  "http://127.0.0.1:${edge_port}/healthz" >/dev/null || die "Bridge edge health check failed."

"${compose[@]}" ps
printf '[Bridge] edge ready at 127.0.0.1:%s with application-independent routing.\n' "${edge_port}"
if command -v bridge >/dev/null 2>&1; then
  bridge list || true
fi
