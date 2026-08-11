#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"

die() {
  printf '[Bridge] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -r "${env_file}" ]] || die "Missing or unreadable ${env_file}."

get_env_value() {
  local key="$1" fallback="$2" value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}

edge_port="$(get_env_value EDGE_PORT 18080)"
[[ "${edge_port}" =~ ^[0-9]+$ ]] || die "EDGE_PORT must be an integer."
(( edge_port >= 1 && edge_port <= 65535 )) || die "EDGE_PORT must be between 1 and 65535."

for key in ALGOQUEST_ORIGIN INTQWQ_ORIGIN; do
  origin="$(get_env_value "${key}" "")"
  [[ "${origin}" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || \
    die "${key} must be an http://127.0.0.1:<port> origin; found '${origin}'."
done

printf '[Bridge] network boundary OK: edge=127.0.0.1:%s, origins=host-loopback\n' "${edge_port}"
