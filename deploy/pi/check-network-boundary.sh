#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"

[[ -f "${env_file}" ]] || { echo "[Bridge] missing ${env_file}" >&2; exit 1; }
get_env() {
  local key="$1" fallback="$2" value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}

edge_port="$(get_env EDGE_PORT 18080)"
state_dir="$(get_env BRIDGE_STATE_DIR /var/lib/intqwq-bridge)"

[[ "${edge_port}" =~ ^[0-9]+$ ]] && (( edge_port >= 1 && edge_port <= 65535 )) || {
  echo "[Bridge] EDGE_PORT must be between 1 and 65535." >&2
  exit 1
}
[[ "${state_dir}" == /* ]] || { echo "[Bridge] BRIDGE_STATE_DIR must be absolute." >&2; exit 1; }
[[ -d "${state_dir}/registry" && -d "${state_dir}/nginx/routes" ]] || {
  echo "[Bridge] registry state is missing; run sudo bash deploy/pi/install-cli.sh first." >&2
  exit 1
}

# Registered proxy origins are deliberately restricted to host loopback. Recheck
# persisted manifests so manual state edits cannot weaken the ingress boundary.
if command -v jq >/dev/null; then
  shopt -s nullglob
  for manifest in "${state_dir}/registry"/*.json; do
    jq -e '
      .version == 1 and
      all(.routes[];
        ((.origin? // "") == "") or
        (.origin | test("^http://127\\.0\\.0\\.1:[0-9]{1,5}$"))
      )
    ' "${manifest}" >/dev/null || {
      echo "[Bridge] invalid persisted registration: ${manifest}" >&2
      exit 1
    }
  done
  shopt -u nullglob
fi

printf '[Bridge] boundary ok: edge=127.0.0.1:%s state=%s\n' "${edge_port}" "${state_dir}"
