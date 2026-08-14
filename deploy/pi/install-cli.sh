#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo bash deploy/pi/install-cli.sh" >&2; exit 77; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"
example_env="${project_root}/.env.example"
operator_user="${BRIDGE_OPERATOR_USER:-${SUDO_USER:-root}}"
config_dir="/etc/intqwq-bridge"
config_file="${config_dir}/config"
cli_path="${BRIDGE_CLI_PATH:-/usr/local/sbin/bridge}"

[[ -f "${env_file}" ]] || cp "${example_env}" "${env_file}"
chmod 600 "${env_file}"
get_env() {
  local key="$1" fallback="$2" value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}

state_dir="$(get_env BRIDGE_STATE_DIR /var/lib/intqwq-bridge)"
edge_port="$(get_env EDGE_PORT 18080)"
tunnel_name="$(get_env BRIDGE_TUNNEL_NAME bridge)"

[[ "${state_dir}" == /* ]] || { echo "BRIDGE_STATE_DIR must be absolute." >&2; exit 1; }
[[ "${state_dir}" != *$'\n'* && "${state_dir}" != *$'\r'* ]] || { echo "Invalid BRIDGE_STATE_DIR." >&2; exit 1; }
[[ "${edge_port}" =~ ^[0-9]+$ ]] && (( edge_port >= 1 && edge_port <= 65535 )) || { echo "Invalid EDGE_PORT." >&2; exit 1; }
[[ "${tunnel_name}" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid BRIDGE_TUNNEL_NAME." >&2; exit 1; }
getent passwd "${operator_user}" >/dev/null || { echo "Unknown operator user: ${operator_user}" >&2; exit 1; }

install -d -m 0755 "${state_dir}" "${state_dir}/registry" "${state_dir}/nginx" "${state_dir}/nginx/routes" "${config_dir}"
install -m 0755 "${project_root}/bin/bridge" "${cli_path}"

{
  printf 'BRIDGE_ROOT=%q\n' "${project_root}"
  printf 'BRIDGE_STATE_DIR=%q\n' "${state_dir}"
  printf 'BRIDGE_EDGE_PORT=%q\n' "${edge_port}"
  printf 'BRIDGE_OPERATOR_USER=%q\n' "${operator_user}"
  printf 'BRIDGE_TUNNEL_NAME=%q\n' "${tunnel_name}"
  printf 'BRIDGE_CLI_PATH=%q\n' "${cli_path}"
} > "${config_file}"
chmod 0644 "${config_file}"

echo "[Bridge] Installed registrar CLI: ${cli_path}"
echo "[Bridge] Registry state: ${state_dir}"
