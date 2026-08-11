#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || {
  echo "Run as root: sudo bash deploy/pi/clean-install.sh" >&2
  exit 77
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bridge_root="$(cd "${script_dir}/../.." && pwd)"
operator_user="${CLEAN_INSTALL_OPERATOR_USER:-${SUDO_USER:-root}}"
operator_home="$(getent passwd "${operator_user}" | cut -d: -f6)"
operator_group="$(id -gn "${operator_user}")"
algoquest_root="${ALGOQUEST_ROOT:-${operator_home}/AlgoQuest}"
intqwq_root="${INTQWQ_ROOT:-${operator_home}/intqwq.com}"
wait_timeout="${CLEAN_INSTALL_WAIT_TIMEOUT:-180}"
skip_pull=0
plan_only=0
state_dir=""

usage() {
  cat <<'USAGE'
Usage: sudo bash deploy/pi/clean-install.sh [--plan] [--skip-pull]

DESTROYS the existing AlgoQuest database and Judge volumes, removes the old
shared services and containers, and installs a new empty architecture:

  Cloudflare -> Bridge 127.0.0.1:18080
                 -> AlgoQuest 127.0.0.1:18081
                 -> intqwq.com 127.0.0.1:18082

Defaults:
  AlgoQuest:  <sudo-caller-home>/AlgoQuest
  intqwq.com: <sudo-caller-home>/intqwq.com
  Bridge:     the repository containing this script

The script preserves external deployment secrets in a private local state
directory. It does not back up or migrate application data.

Environment:
  CLEAN_INSTALL_CONFIRM=ERASE-ALGOQUEST-DATABASE
      Allows non-interactive confirmation. Otherwise the phrase is prompted.
  CLEAN_INSTALL_WAIT_TIMEOUT=180
      Health-check timeout in seconds.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --skip-pull)
      skip_pull=1
      shift
      ;;
    --plan)
      plan_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

log() {
  printf '\n[Clean install] %s\n' "$*"
}

die() {
  printf '\n[Clean install] ERROR: %s\n' "$*" >&2
  exit 1
}

on_exit() {
  local status="$?"
  trap - EXIT
  if [[ "${status}" -ne 0 ]]; then
    printf '\n[Clean install] Failed. Review the error before rerunning.\n' >&2
    [[ -z "${state_dir}" ]] || printf '[Clean install] Preserved configuration: %s\n' "${state_dir}" >&2
  fi
  exit "${status}"
}
trap on_exit EXIT

run_as_operator() {
  if [[ "${operator_user}" == "root" ]]; then
    env HOME="${operator_home}" "$@"
  else
    sudo -u "${operator_user}" -H "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null || die "Missing required command: $1"
}

require_clean_repo() {
  local repo="$1"
  local label="$2"
  local changes
  changes="$(run_as_operator git -C "${repo}" status --porcelain --untracked-files=all)"
  [[ -z "${changes}" ]] || {
    printf '%s\n' "${changes}" >&2
    die "${label} has local changes. Preserve or commit them before clean installation."
  }
}

update_repo() {
  local repo="$1"
  local label="$2"
  require_clean_repo "${repo}" "${label}"
  if [[ "${skip_pull}" == "0" ]]; then
    run_as_operator git -C "${repo}" switch main
    run_as_operator git -C "${repo}" pull --ff-only
  fi
  run_as_operator git -C "${repo}" rev-parse HEAD | tee "${state_dir}/${label}.commit"
}

get_env_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local temporary
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die "${key} contains a newline."
  temporary="$(mktemp "${file}.XXXXXX")"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      if (!replaced) print key "=" value
      replaced = 1
      next
    }
    { print }
    END { if (!replaced) print key "=" value }
  ' "${file}" > "${temporary}"
  install -m 0600 -o "${operator_user}" -g "${operator_group}" "${temporary}" "${file}"
  rm -f "${temporary}"
}

is_missing_value() {
  local value="$1"
  [[ -z "${value}" || "${value}" == CHANGE_ME_* ]]
}

validate_volume_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Unsafe Docker volume name: $1"
}

compose_down_if_configured() {
  local root="$1"
  local env_file="$2"
  shift 2
  [[ -f "${root}/compose.yml" && -f "${env_file}" ]] || return 0
  docker compose --project-directory "${root}" --env-file "${env_file}" \
    "$@" down --remove-orphans --volumes || true
}

probe_url() {
  curl -fsS --connect-timeout 3 --max-time 10 "$1" >/dev/null 2>&1
}

wait_for_url() {
  local url="$1"
  local deadline=$((SECONDS + wait_timeout))
  while (( SECONDS < deadline )); do
    probe_url "${url}" && return 0
    sleep 2
  done
  return 1
}

for command_name in awk curl cut date docker env find getent git grep id install mktemp readlink sed ss sudo systemctl tail tee; do
  require_command "${command_name}"
done
[[ -n "${operator_home}" ]] || die "Could not resolve the operator home directory."
[[ "${wait_timeout}" =~ ^[1-9][0-9]*$ ]] || die "CLEAN_INSTALL_WAIT_TIMEOUT must be a positive integer."

for repo in "${algoquest_root}" "${intqwq_root}" "${bridge_root}"; do
  [[ -d "${repo}/.git" ]] || die "Missing Git checkout: ${repo}"
done
[[ -f "${algoquest_root}/.env.pi" ]] || die "Missing ${algoquest_root}/.env.pi; external service secrets cannot be preserved."
[[ -f "${algoquest_root}/.env.pi.example" ]] || die "Missing AlgoQuest environment template."
[[ -f "${intqwq_root}/.env.example" ]] || die "Missing intqwq.com environment template."
[[ -f "${bridge_root}/.env.example" ]] || die "Missing Bridge environment template."

install_id="$(date -u +%Y%m%dT%H%M%SZ)"
state_dir="${operator_home}/clean-install-state/${install_id}"
install -d -m 0700 -o "${operator_user}" -g "${operator_group}" "${state_dir}"

log "Preflight: AlgoQuest=${algoquest_root}, intqwq.com=${intqwq_root}, Bridge=${bridge_root}"
require_clean_repo "${algoquest_root}" "AlgoQuest"
require_clean_repo "${intqwq_root}" "intqwq"
require_clean_repo "${bridge_root}" "Bridge"

install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${algoquest_root}/.env.pi" "${state_dir}/algoquest.env.pi.before"
[[ ! -f "${intqwq_root}/.env" ]] || install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${intqwq_root}/.env" "${state_dir}/intqwq.env.before"
[[ ! -f "${bridge_root}/.env" ]] || install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${bridge_root}/.env" "${state_dir}/bridge.env.before"

resend_api_key="$(get_env_value "${algoquest_root}/.env.pi" RESEND_API_KEY)"
resend_from_email="$(get_env_value "${algoquest_root}/.env.pi" RESEND_FROM_EMAIL)"
turnstile_site_key="$(get_env_value "${algoquest_root}/.env.pi" TURNSTILE_SITE_KEY)"
turnstile_secret_key="$(get_env_value "${algoquest_root}/.env.pi" TURNSTILE_SECRET_KEY)"
site_owner_email="$(get_env_value "${algoquest_root}/.env.pi" SITE_OWNER_EMAIL)"
is_missing_value "${resend_api_key}" && die "RESEND_API_KEY is missing; refusing to erase before a clean install can succeed."
is_missing_value "${turnstile_site_key}" && die "TURNSTILE_SITE_KEY is missing; refusing to erase before a clean install can succeed."
is_missing_value "${turnstile_secret_key}" && die "TURNSTILE_SECRET_KEY is missing; refusing to erase before a clean install can succeed."
[[ -n "${site_owner_email}" ]] || die "SITE_OWNER_EMAIL is missing; refusing to erase before a clean install can succeed."

postgres_volume="$(get_env_value "${algoquest_root}/.env.pi" POSTGRES_VOLUME)"
judge_work_volume="$(get_env_value "${algoquest_root}/.env.pi" JUDGE_WORK_VOLUME)"
judge_cache_volume="$(get_env_value "${algoquest_root}/.env.pi" JUDGE_CACHE_VOLUME)"
judge_queue_volume="$(get_env_value "${algoquest_root}/.env.pi" JUDGE_QUEUE_VOLUME)"
postgres_volume="${postgres_volume:-algoquest-postgres-data}"
judge_work_volume="${judge_work_volume:-algoquest-judge-work}"
judge_cache_volume="${judge_cache_volume:-algoquest-judge-cache}"
judge_queue_volume="${judge_queue_volume:-algoquest-judge-queue}"
running_db_container="$(docker compose --project-directory "${algoquest_root}" \
  --env-file "${algoquest_root}/.env.pi" --profile all ps -q db 2>/dev/null || true)"
running_postgres_volume=""
if [[ -n "${running_db_container}" ]]; then
  running_postgres_volume="$(docker inspect "${running_db_container}" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')"
  [[ -n "${running_postgres_volume}" ]] || \
    die "The running PostgreSQL data mount is not a named volume; refusing automatic deletion."
fi
candidate_volumes=(
  "${postgres_volume}"
  "${running_postgres_volume:-${postgres_volume}}"
  "${judge_work_volume}"
  "${judge_cache_volume}"
  "${judge_queue_volume}"
  algoquest-postgres-data
  algoquest-judge-work
  algoquest-judge-cache
  algoquest-judge-queue
)
volumes=()
for candidate_volume in "${candidate_volumes[@]}"; do
  validate_volume_name "${candidate_volume}"
  duplicate=0
  for volume in "${volumes[@]}"; do
    [[ "${volume}" != "${candidate_volume}" ]] || duplicate=1
  done
  [[ "${duplicate}" == "1" ]] || volumes+=("${candidate_volume}")
done
printf '%s\n' "${volumes[@]}" > "${state_dir}/deleted-volume-names.txt"

systemctl status algoquest algoquest-cloudflared intqwq-shared intqwq-site \
  bridge-edge bridge-cloudflared --no-pager > "${state_dir}/services.before.txt" 2>&1 || true
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
  > "${state_dir}/containers.before.txt"
docker volume ls > "${state_dir}/volumes.before.txt"
for volume in "${volumes[@]}"; do
  docker volume inspect "${volume}" >> "${state_dir}/volume-inspection.before.json" 2>/dev/null || true
done

printf '\nTHIS WILL PERMANENTLY DELETE:\n'
printf '  - the AlgoQuest PostgreSQL database volume: %s\n' "${postgres_volume}"
printf '  - all AlgoQuest Judge work/cache/queue volumes\n'
printf '  - exact Docker volume list:\n'
printf '      %s\n' "${volumes[@]}"
printf '  - old Bridge, AlgoQuest, and intqwq.com containers and services\n'
printf '  - the old shared-site state at /var/lib/intqwq-site\n'
printf 'No application data backup or migration will be made.\n\n'

if [[ "${plan_only}" == "1" ]]; then
  log "Plan complete; no services, containers, volumes, or repositories were changed"
  printf 'Preserved configuration preview: %s\n' "${state_dir}"
  exit 0
fi

confirmation="${CLEAN_INSTALL_CONFIRM:-}"
if [[ -z "${confirmation}" ]]; then
  printf 'Type ERASE-ALGOQUEST-DATABASE to continue: '
  read -r confirmation
fi
[[ "${confirmation}" == "ERASE-ALGOQUEST-DATABASE" ]] || die "Destructive confirmation was not received. Nothing was erased."

log "Updating all three repositories before the destructive step"
update_repo "${algoquest_root}" "AlgoQuest"
update_repo "${intqwq_root}" "intqwq"
update_repo "${bridge_root}" "Bridge"

log "Stopping and uninstalling old runtime services"
units=(bridge-cloudflared bridge-edge intqwq-shared intqwq-site algoquest-cloudflared algoquest)
for unit in "${units[@]}"; do
  systemctl disable --now "${unit}.service" 2>/dev/null || true
done

compose_down_if_configured "${bridge_root}" "${bridge_root}/.env"
compose_down_if_configured "${intqwq_root}" "${intqwq_root}/.env"
compose_down_if_configured "${algoquest_root}" "${algoquest_root}/.env.pi" --profile all
docker rm -f intqwq-cloudflared 2>/dev/null || true

log "Deleting the old AlgoQuest database and Judge volumes"
for volume in "${volumes[@]}"; do
  if docker volume inspect "${volume}" >/dev/null 2>&1; then
    docker volume rm "${volume}"
  fi
done

legacy_state=/var/lib/intqwq-site
if [[ -e "${legacy_state}" || -L "${legacy_state}" ]]; then
  resolved_legacy_state="$(readlink -f -- "${legacy_state}")"
  [[ "${resolved_legacy_state}" == "${legacy_state}" ]] || \
    die "Refusing to delete unexpected shared-state target: ${resolved_legacy_state}"
  rm -rf -- "${resolved_legacy_state}"
fi

for unit in "${units[@]}"; do
  rm -f -- "/etc/systemd/system/${unit}.service"
done
rm -f -- /etc/default/intqwq-shared
systemctl daemon-reload

log "Creating fresh environment files and rotating internal credentials"
install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${algoquest_root}/.env.pi.example" "${algoquest_root}/.env.pi"
set_env_value "${algoquest_root}/.env.pi" RESEND_API_KEY "${resend_api_key}"
[[ -z "${resend_from_email}" ]] || set_env_value "${algoquest_root}/.env.pi" RESEND_FROM_EMAIL "${resend_from_email}"
set_env_value "${algoquest_root}/.env.pi" TURNSTILE_SITE_KEY "${turnstile_site_key}"
set_env_value "${algoquest_root}/.env.pi" TURNSTILE_SECRET_KEY "${turnstile_secret_key}"
set_env_value "${algoquest_root}/.env.pi" SITE_OWNER_EMAIL "${site_owner_email}"
set_env_value "${algoquest_root}/.env.pi" POSTGRES_VOLUME algoquest-postgres-data
set_env_value "${algoquest_root}/.env.pi" JUDGE_WORK_VOLUME algoquest-judge-work
set_env_value "${algoquest_root}/.env.pi" JUDGE_CACHE_VOLUME algoquest-judge-cache
set_env_value "${algoquest_root}/.env.pi" JUDGE_QUEUE_VOLUME algoquest-judge-queue

install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${intqwq_root}/.env.example" "${intqwq_root}/.env"
install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${bridge_root}/.env.example" "${bridge_root}/.env"

log "Installing a fresh empty AlgoQuest origin on 127.0.0.1:18081"
ALGOQUEST_OPERATOR_USER="${operator_user}" bash "${algoquest_root}/deploy/pi/bootstrap-ubuntu.sh"
wait_for_url http://127.0.0.1:18081/healthz || die "Fresh AlgoQuest gateway is not healthy."
wait_for_url http://127.0.0.1:18081/api/health || die "Fresh AlgoQuest API is not healthy."

fresh_db_user="$(get_env_value "${algoquest_root}/.env.pi" POSTGRES_USER)"
fresh_db_name="$(get_env_value "${algoquest_root}/.env.pi" POSTGRES_DB)"
fresh_db_user="${fresh_db_user:-algoquest}"
fresh_db_name="${fresh_db_name:-algoquest}"
user_count="$(docker compose --project-directory "${algoquest_root}" \
  --env-file "${algoquest_root}/.env.pi" --profile all exec -T db \
  psql -v ON_ERROR_STOP=1 -U "${fresh_db_user}" -d "${fresh_db_name}" \
  -Atc 'SELECT count(*) FROM users;')"
[[ "${user_count}" == "0" ]] || die "Fresh AlgoQuest database unexpectedly contains ${user_count} user row(s)."

log "Installing a fresh intqwq.com origin on 127.0.0.1:18082"
bash "${intqwq_root}/deploy/pi/bootstrap-ubuntu.sh"
wait_for_url http://127.0.0.1:18082/healthz || die "Fresh intqwq.com origin is not healthy."

log "Installing the only public edge and Cloudflare tunnel on 127.0.0.1:18080"
BRIDGE_OPERATOR_USER="${operator_user}" BRIDGE_TUNNEL_NAME=bridge \
  bash "${bridge_root}/deploy/pi/bootstrap-ubuntu.sh"
bash "${bridge_root}/deploy/pi/status.sh"
wait_for_url https://game.intqwq.com/api/health || die "Public AlgoQuest route is not healthy."
wait_for_url https://game.intqwq.com/ || die "Public AlgoQuest page is not healthy."
wait_for_url https://intqwq.com/ || die "Public intqwq.com page is not healthy."

log "Deleting the obsolete named Cloudflare tunnel 'algoquest', if present"
old_tunnel_id="$(run_as_operator cloudflared tunnel list --output json 2>/dev/null | \
  jq -r '[.[] | select(.name == "algoquest" and ((.deletedAt // "") == ""))][0].id // empty')"
if [[ -n "${old_tunnel_id}" ]]; then
  run_as_operator cloudflared tunnel delete -f "${old_tunnel_id}"
  rm -f -- "${operator_home}/.cloudflared/${old_tunnel_id}.json"
fi
rm -f -- "${operator_home}/.cloudflared/algoquest.yml"
for old_unit in algoquest-cloudflared intqwq-shared; do
  systemctl is-active --quiet "${old_unit}.service" && die "Obsolete service is still active: ${old_unit}"
done
systemctl is-active --quiet bridge-cloudflared.service || die "Bridge Cloudflare service is not active."

{
  printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'algoquest_database=empty\n'
  printf 'algoquest_origin=http://127.0.0.1:18081\n'
  printf 'intqwq_origin=http://127.0.0.1:18082\n'
  printf 'bridge_edge=http://127.0.0.1:18080\n'
} > "${state_dir}/clean-install.completed.txt"
chown -R "${operator_user}:${operator_group}" "${state_dir}"
find "${state_dir}" -type f -exec chmod 0600 {} +

log "Clean installation complete"
printf 'AlgoQuest database: empty (0 users)\n'
printf 'Architecture: one Bridge edge, one Bridge Cloudflare tunnel, two independent origins\n'
printf 'Preserved deployment configuration: %s\n' "${state_dir}"
