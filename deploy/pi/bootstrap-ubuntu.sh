#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo bash install.sh" >&2; exit 77; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] || { echo "Ubuntu or Debian is required." >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
operator_user="${BRIDGE_OPERATOR_USER:-${SUDO_USER:-root}}"
architecture="$(dpkg --print-architecture)"
codename="${VERSION_CODENAME:-bookworm}"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git gnupg jq sudo

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  conflicting=()
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null | grep -q '^ii ' && conflicting+=("${package}")
  done
  (( ${#conflicting[@]} == 0 )) || DEBIAN_FRONTEND=noninteractive apt-get remove -y "${conflicting[@]}"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${codename}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
[[ "${operator_user}" == "root" ]] || usermod -aG docker "${operator_user}"

if ! command -v cloudflared >/dev/null; then
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  chmod a+r /usr/share/keyrings/cloudflare-main.gpg
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
fi

chmod +x "${project_root}/bin/bridge" "${script_dir}"/*.sh
BRIDGE_OPERATOR_USER="${operator_user}" "${script_dir}/install-cli.sh"
"${script_dir}/deploy.sh"
"${script_dir}/install-systemd.sh"
BRIDGE_OPERATOR_USER="${operator_user}" "${script_dir}/configure-cloudflare.sh"
"${script_dir}/status.sh"

echo "[Bridge] Bootstrap complete. Bridge is now ready before any application is installed."
echo "[Bridge] Applications register themselves with: sudo bridge register <manifest.json>"
