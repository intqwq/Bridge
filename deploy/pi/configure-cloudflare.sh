#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo bash deploy/pi/configure-cloudflare.sh" >&2; exit 77; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
env_file="${project_root}/.env"
tunnel_name="${BRIDGE_TUNNEL_NAME:-bridge}"
operator_user="${BRIDGE_OPERATOR_USER:-${SUDO_USER:-root}}"
tmp_config=""

die() { printf '[Bridge] ERROR: %s\n' "$*" >&2; exit 1; }
get_env_value() {
  local key="$1" fallback="$2" value
  value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
  printf '%s' "${value:-${fallback}}"
}
cleanup() { [[ -z "${tmp_config}" ]] || rm -f "${tmp_config}"; }
trap cleanup EXIT

[[ -f "${env_file}" ]] || die "Missing ${env_file}. Run deploy.sh first."
command -v cloudflared >/dev/null || die "cloudflared is missing."
command -v jq >/dev/null || die "jq is missing."
getent passwd "${operator_user}" >/dev/null || die "Unknown operator user: ${operator_user}"
[[ "${tunnel_name}" =~ ^[A-Za-z0-9_-]+$ ]] || die "BRIDGE_TUNNEL_NAME contains unsupported characters."

edge_port="$(get_env_value EDGE_PORT 18080)"
algoquest_domain="$(get_env_value ALGOQUEST_DOMAIN game.intqwq.com)"
intqwq_domain="$(get_env_value INTQWQ_DOMAIN intqwq.com)"
intqwq_www_domain="$(get_env_value INTQWQ_WWW_DOMAIN www.intqwq.com)"
for domain in "${algoquest_domain}" "${intqwq_domain}" "${intqwq_www_domain}"; do
  [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid hostname: ${domain}"
done
[[ "${edge_port}" =~ ^[0-9]+$ ]] || die "EDGE_PORT must be an integer."

operator_home="$(getent passwd "${operator_user}" | cut -d: -f6)"
operator_group="$(id -gn "${operator_user}")"
as_operator() {
  if [[ "${operator_user}" == "root" ]]; then HOME="${operator_home}" "$@"; else sudo -u "${operator_user}" -H "$@"; fi
}

cloudflare_dir="${operator_home}/.cloudflared"
install -d -m 0700 -o "${operator_user}" -g "${operator_group}" "${cloudflare_dir}"
if [[ ! -f "${cloudflare_dir}/cert.pem" ]]; then
  echo "[Bridge] Authorize Cloudflare and select the intqwq.com zone."
  as_operator cloudflared tunnel login
fi

find_tunnel_id() {
  as_operator cloudflared tunnel list --output json 2>/dev/null | \
    jq -r --arg name "${tunnel_name}" '[.[] | select(.name == $name and ((.deletedAt // "") == ""))][0].id // empty'
}

tunnel_id="$(find_tunnel_id)"
if [[ -z "${tunnel_id}" ]]; then
  as_operator cloudflared tunnel create "${tunnel_name}"
  tunnel_id="$(find_tunnel_id)"
fi
[[ -n "${tunnel_id}" ]] || die "Could not resolve tunnel '${tunnel_name}'."
credentials_file="${cloudflare_dir}/${tunnel_id}.json"
[[ -f "${credentials_file}" ]] || die "Missing tunnel credentials: ${credentials_file}"

config_file="${cloudflare_dir}/bridge.yml"
tmp_config="$(mktemp)"
cat > "${tmp_config}" <<CLOUDFLARED_CONFIG
tunnel: ${tunnel_id}
credentials-file: ${credentials_file}
ingress:
  - hostname: ${algoquest_domain}
    service: http://127.0.0.1:${edge_port}
  - hostname: ${intqwq_domain}
    service: http://127.0.0.1:${edge_port}
  - hostname: ${intqwq_www_domain}
    service: http://127.0.0.1:${edge_port}
  - service: http_status:404
CLOUDFLARED_CONFIG
install -m 0600 -o "${operator_user}" -g "${operator_group}" "${tmp_config}" "${config_file}"
rm -f "${tmp_config}"
tmp_config=""

as_operator cloudflared tunnel --config "${config_file}" ingress validate
cloudflared_path="$(command -v cloudflared)"
cat > /etc/systemd/system/bridge-cloudflared.service <<SYSTEMD_UNIT
[Unit]
Description=Shared intqwq Cloudflare Tunnel
Requires=bridge-edge.service
After=network-online.target bridge-edge.service
Wants=network-online.target

[Service]
Type=simple
User=${operator_user}
Group=${operator_group}
ExecStart=${cloudflared_path} --no-autoupdate --config ${config_file} tunnel run ${tunnel_id}
Restart=always
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
SYSTEMD_UNIT

systemd-analyze verify /etc/systemd/system/bridge-cloudflared.service
systemctl daemon-reload
systemctl enable --now bridge-cloudflared.service
systemctl is-active --quiet bridge-cloudflared.service || die "bridge-cloudflared.service did not start."

for domain in "${algoquest_domain}" "${intqwq_domain}" "${intqwq_www_domain}"; do
  as_operator cloudflared tunnel route dns --overwrite-dns "${tunnel_id}" "${domain}"
done

echo "[Bridge] Tunnel ${tunnel_id} routes every hostname through http://127.0.0.1:${edge_port}."
