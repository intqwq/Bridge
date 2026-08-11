#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || {
  echo "Run as root: sudo bash deploy/pi/migrate-from-shared.sh" >&2
  exit 77
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bridge_root="$(cd "${script_dir}/../.." && pwd)"
operator_user="${MIGRATION_OPERATOR_USER:-${SUDO_USER:-root}}"
operator_home="$(getent passwd "${operator_user}" | cut -d: -f6)"
operator_group="$(id -gn "${operator_user}")"
algoquest_root="${ALGOQUEST_ROOT:-${operator_home}/AlgoQuest}"
intqwq_root="${INTQWQ_ROOT:-${operator_home}/intqwq.com}"
edge_port="${BRIDGE_MIGRATION_EDGE_PORT:-18080}"
wait_timeout="${MIGRATION_WAIT_TIMEOUT:-180}"
backup_copy_to="${MIGRATION_BACKUP_COPY_TO:-}"
assume_yes=0
retire_legacy=0
skip_pull=0
writes_frozen=0
backup_dir=""
backup_archive=""

usage() {
  cat <<'USAGE'
Usage: sudo bash deploy/pi/migrate-from-shared.sh [options]

Safely migrates ~/AlgoQuest and ~/intqwq.com from their shared gateway to
Bridge. Durable AlgoQuest data remains in its existing named PostgreSQL volume.

Options:
  --backup-copy-to DEST  Copy the private backup archive over SSH with scp.
                         Example: backup@host:/srv/private-backups/
  --retire-legacy       Stop old tunnel processes after all checks and a prompt.
  --skip-pull           Do not switch to or pull the main branches.
  --yes                 Accept migration prompts. Requires --backup-copy-to or
                         MIGRATION_ALLOW_LOCAL_BACKUP=1.
  -h, --help            Show this help.

Environment overrides:
  ALGOQUEST_ROOT                 Default: <operator-home>/AlgoQuest
  INTQWQ_ROOT                    Default: <operator-home>/intqwq.com
  MIGRATION_OPERATOR_USER       Default: the sudo caller
  BRIDGE_MIGRATION_EDGE_PORT    Default: 18080
  MIGRATION_WAIT_TIMEOUT        Public/local health wait in seconds; default 180
  MIGRATION_BACKUP_COPY_TO      Same as --backup-copy-to
  MIGRATION_ALLOW_LOCAL_BACKUP  Set to 1 to explicitly accept local-only backup

This script never removes Docker volumes and never runs Compose with -v.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --backup-copy-to)
      (( $# >= 2 )) || { echo "--backup-copy-to needs a destination" >&2; exit 64; }
      backup_copy_to="$2"
      shift 2
      ;;
    --retire-legacy)
      retire_legacy=1
      shift
      ;;
    --skip-pull)
      skip_pull=1
      shift
      ;;
    --yes)
      assume_yes=1
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
  printf '\n[Migration] %s\n' "$*"
}

die() {
  printf '\n[Migration] ERROR: %s\n' "$*" >&2
  exit 1
}

run_as_operator() {
  if [[ "${operator_user}" == "root" ]]; then
    HOME="${operator_home}" "$@"
  else
    sudo -u "${operator_user}" -H "$@"
  fi
}

confirm() {
  local prompt="$1"
  local phrase="$2"
  local answer=""
  if [[ "${assume_yes}" == "1" ]]; then
    return 0
  fi
  printf '\n%s\nType %s to continue: ' "${prompt}" "${phrase}"
  read -r answer
  [[ "${answer}" == "${phrase}" ]] || die "Confirmation was not received. No further changes were made."
}

compose_algoquest() {
  docker compose \
    --project-directory "${algoquest_root}" \
    --env-file "${algoquest_root}/.env.pi" \
    --profile all "$@"
}

thaw_writes() {
  [[ "${writes_frozen}" == "1" ]] || return 0
  log "Restarting AlgoQuest write services after an interrupted migration"
  if ! compose_algoquest start api judge judge-worker; then
    compose_algoquest up -d api judge judge-worker || true
  fi
  writes_frozen=0
}

on_exit() {
  local status="$?"
  trap - EXIT
  if [[ "${status}" -ne 0 ]]; then
    thaw_writes || true
    printf '\n[Migration] Failed. Existing Docker volumes were not removed.\n' >&2
    [[ -z "${backup_dir}" ]] || printf '[Migration] Backup directory: %s\n' "${backup_dir}" >&2
  fi
  exit "${status}"
}
trap on_exit EXIT

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
    die "${label} has local changes. Preserve or commit them before migration."
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
  run_as_operator git -C "${repo}" rev-parse HEAD | tee "${backup_dir}/${label}.migration.commit"
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

probe_url() {
  local url="$1"
  local host_header="${2:-}"
  if [[ -n "${host_header}" ]]; then
    curl --noproxy '*' -fsS --connect-timeout 3 --max-time 10 \
      -H "Host: ${host_header}" "${url}" >/dev/null 2>&1
  else
    curl -fsS --connect-timeout 3 --max-time 10 "${url}" >/dev/null 2>&1
  fi
}

wait_for_url() {
  local url="$1"
  local host_header="${2:-}"
  local deadline=$((SECONDS + wait_timeout))
  while (( SECONDS < deadline )); do
    probe_url "${url}" "${host_header}" && return 0
    sleep 2
  done
  return 1
}

database_dump() {
  local destination="$1"
  compose_algoquest exec -T db \
    pg_dump -U "${aq_db_user}" -d "${aq_db_name}" -Fc > "${destination}"
  [[ -s "${destination}" ]] || die "PostgreSQL produced an empty backup: ${destination}"
  compose_algoquest exec -T db pg_restore -l < "${destination}" \
    > "${destination}.contents.txt"
  [[ -s "${destination}.contents.txt" ]] || die "PostgreSQL could not read the backup catalog."
  sha256sum "${destination}" >> "${backup_dir}/SHA256SUMS"
}

query_counts() {
  local destination="$1"
  local sql
  sql="SELECT 'registered_users', count(*) FROM users WHERE is_guest = false
UNION ALL SELECT 'quest_progress', count(*) FROM quest_progress
UNION ALL SELECT 'submissions', count(*) FROM submissions
ORDER BY 1;"
  compose_algoquest exec -T db \
    psql -v ON_ERROR_STOP=1 -U "${aq_db_user}" -d "${aq_db_name}" \
    -At -F ',' -c "${sql}" | tee "${destination}"
}

verify_counts_not_lower() {
  awk -F, '
    NR == FNR { before[$1] = $2 + 0; next }
    !($1 in before) { printf "missing metric after migration: %s\n", $1 > "/dev/stderr"; bad = 1; next }
    ($2 + 0) < before[$1] {
      printf "row count decreased for %s: %d -> %d\n", $1, before[$1], $2 > "/dev/stderr"
      bad = 1
    }
    END { exit bad }
  ' "${backup_dir}/counts.before.csv" "${backup_dir}/counts.after.csv" || \
    die "A durable row count decreased. Stop and inspect the recorded volume before allowing writes."
}

record_database_mount() {
  local destination="$1"
  local db_container
  db_container="$(compose_algoquest ps -q db)"
  [[ -n "${db_container}" ]] || die "AlgoQuest database container is not running."
  docker inspect "${db_container}" \
    --format '{{range .Mounts}}{{println .Name "->" .Destination}}{{end}}' \
    | tee "${destination}"
  grep -F "${aq_db_volume} -> /var/lib/postgresql/data" "${destination}" >/dev/null || \
    die "The database is not mounted on expected volume ${aq_db_volume}."
}

package_and_copy_backup() {
  local reason="$1"
  local backup_parent backup_name temporary_archive
  chown -R "${operator_user}:${operator_group}" "${backup_dir}"
  chmod 0700 "${backup_dir}"
  find "${backup_dir}" -type f -exec chmod 0600 {} +
  backup_parent="$(dirname "${backup_dir}")"
  backup_name="$(basename "${backup_dir}")"
  backup_archive="${backup_parent}/${backup_name}.tar.gz"
  temporary_archive="${backup_archive}.tmp"
  tar -C "${backup_parent}" -czf "${temporary_archive}" "${backup_name}"
  chown "${operator_user}:${operator_group}" "${temporary_archive}"
  chmod 0600 "${temporary_archive}"
  mv -f "${temporary_archive}" "${backup_archive}"
  if [[ -n "${backup_copy_to}" ]]; then
    log "Copying ${reason} backup archive to ${backup_copy_to}"
    run_as_operator scp -p "${backup_archive}" "${backup_copy_to}"
  elif [[ "${MIGRATION_ALLOW_LOCAL_BACKUP:-0}" == "1" ]]; then
    log "Local-only backup explicitly accepted: ${backup_archive}"
  else
    confirm "Copy ${backup_archive} to another machine in a second terminal. Local-only backup is not sufficient for strict recovery." "BACKUP-COPIED"
  fi
}

for command_name in awk curl docker find getent git grep install sha256sum ss sudo systemctl tar tee; do
  require_command "${command_name}"
done
[[ -z "${backup_copy_to}" ]] || require_command scp
[[ -n "${operator_home}" ]] || die "Could not resolve the operator home directory."
[[ "${edge_port}" =~ ^[0-9]+$ ]] || die "BRIDGE_MIGRATION_EDGE_PORT must be an integer."
(( edge_port >= 1 && edge_port <= 65535 )) || die "Bridge edge port is out of range."
[[ "${wait_timeout}" =~ ^[1-9][0-9]*$ ]] || die "MIGRATION_WAIT_TIMEOUT must be a positive integer."
[[ "${edge_port}" != "8080" ]] || die "Port 8080 belongs to the live legacy gateway; use 18080 for Bridge."
[[ "${MIGRATION_ALLOW_LOCAL_BACKUP:-0}" == "0" || "${MIGRATION_ALLOW_LOCAL_BACKUP:-0}" == "1" ]] || \
  die "MIGRATION_ALLOW_LOCAL_BACKUP must be 0 or 1."
if [[ "${assume_yes}" == "1" && -z "${backup_copy_to}" && "${MIGRATION_ALLOW_LOCAL_BACKUP:-0}" != "1" ]]; then
  die "--yes requires --backup-copy-to or MIGRATION_ALLOW_LOCAL_BACKUP=1."
fi

for repo in "${algoquest_root}" "${intqwq_root}" "${bridge_root}"; do
  [[ -d "${repo}/.git" ]] || die "Missing Git checkout: ${repo}"
done
[[ -f "${algoquest_root}/.env.pi" ]] || die "Missing ${algoquest_root}/.env.pi"
[[ -f "${algoquest_root}/compose.yml" ]] || die "Missing AlgoQuest compose.yml"
[[ -f "${intqwq_root}/compose.yml" ]] || die "Missing intqwq.com compose.yml"
[[ -f "${bridge_root}/compose.yml" ]] || die "Missing Bridge compose.yml"

migration_id="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${operator_home}/algoquest-migration-backups/${migration_id}"
install -d -m 0700 -o "${operator_user}" -g "${operator_group}" "${backup_dir}"

log "Preflight: AlgoQuest=${algoquest_root}, intqwq.com=${intqwq_root}, Bridge=${bridge_root}"
require_clean_repo "${algoquest_root}" "AlgoQuest"
require_clean_repo "${intqwq_root}" "intqwq"
require_clean_repo "${bridge_root}" "Bridge"

run_as_operator git -C "${algoquest_root}" rev-parse HEAD | tee "${backup_dir}/AlgoQuest.before.commit"
run_as_operator git -C "${intqwq_root}" rev-parse HEAD | tee "${backup_dir}/intqwq.before.commit"
run_as_operator git -C "${bridge_root}" rev-parse HEAD | tee "${backup_dir}/Bridge.before.commit"
systemctl status algoquest algoquest-cloudflared intqwq-shared --no-pager \
  > "${backup_dir}/services.before.txt" 2>&1 || true
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
  > "${backup_dir}/containers.before.txt"
docker volume ls > "${backup_dir}/volumes.before.txt"
ss -ltnp > "${backup_dir}/ports.before.txt"

legacy_ready=0
if probe_url "http://127.0.0.1:8080/healthz" "game.intqwq.com" && \
   probe_url "http://127.0.0.1:8080/api/health" "game.intqwq.com" && \
   probe_url "http://127.0.0.1:8080/_intqwq_health" "intqwq.com"; then
  legacy_ready=1
  log "Legacy shared gateway is healthy on port 8080"
elif probe_url "http://127.0.0.1:18081/healthz" && \
     probe_url "http://127.0.0.1:18081/api/health" && \
     probe_url "http://127.0.0.1:18082/healthz"; then
  log "Legacy gateway is already retired; both private origins are healthy, so the migration can be re-verified"
else
  die "Neither the complete legacy gateway nor both replacement origins are healthy. Restore service before migration."
fi

install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${algoquest_root}/.env.pi" "${backup_dir}/algoquest.env.pi"
[[ ! -f "${intqwq_root}/.env" ]] || install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${intqwq_root}/.env" "${backup_dir}/intqwq.env"

aq_db_user="$(get_env_value "${algoquest_root}/.env.pi" POSTGRES_USER)"
aq_db_name="$(get_env_value "${algoquest_root}/.env.pi" POSTGRES_DB)"
aq_db_volume="$(get_env_value "${algoquest_root}/.env.pi" POSTGRES_VOLUME)"
aq_db_user="${aq_db_user:-algoquest}"
aq_db_name="${aq_db_name:-algoquest}"
aq_db_volume="${aq_db_volume:-algoquest-postgres-data}"
printf 'database=%s\nuser=%s\nvolume=%s\n' "${aq_db_name}" "${aq_db_user}" "${aq_db_volume}" \
  > "${backup_dir}/database-identity.txt"
docker volume inspect "${aq_db_volume}" > "${backup_dir}/postgres-volume.before.json"
record_database_mount "${backup_dir}/database-mount.before.txt"

log "Creating the first consistent PostgreSQL backup"
database_dump "${backup_dir}/algoquest-live.dump"
package_and_copy_backup "initial"

if [[ "${legacy_ready}" == "1" ]]; then
  confirm "The initial backup is valid. The next phase installs Bridge and changes the three Cloudflare DNS routes." "MIGRATE"
else
  confirm "The initial backup is valid. The next phase re-verifies the already-migrated Bridge routes and origins." "VERIFY-MIGRATION"
fi

log "Updating reviewed repositories"
update_repo "${algoquest_root}" "AlgoQuest"
update_repo "${intqwq_root}" "intqwq"
update_repo "${bridge_root}" "Bridge"

grep -q 'WEB_PORT=18081' "${algoquest_root}/.env.pi.example" || \
  die "AlgoQuest does not contain the private-origin deployment contract."
grep -q 'SITE_PORT:-18082' "${intqwq_root}/compose.yml" || \
  die "intqwq.com does not contain the private-origin deployment contract."

log "Starting Bridge on non-conflicting loopback port ${edge_port}"
[[ -f "${bridge_root}/.env" ]] || install -m 0600 -o "${operator_user}" -g "${operator_group}" \
  "${bridge_root}/.env.example" "${bridge_root}/.env"
set_env_value "${bridge_root}/.env" EDGE_BIND_ADDRESS 127.0.0.1
set_env_value "${bridge_root}/.env" EDGE_PORT "${edge_port}"
set_env_value "${bridge_root}/.env" LEGACY_SHARED_ORIGIN http://host.docker.internal:8080
if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${edge_port}$"; then
  wait_for_url "http://127.0.0.1:${edge_port}/healthz" || \
    die "Port ${edge_port} is occupied by something other than a healthy Bridge edge."
fi
BRIDGE_OPERATOR_USER="${operator_user}" bash "${bridge_root}/deploy/pi/bootstrap-ubuntu.sh"
bash "${bridge_root}/deploy/pi/status.sh"
wait_for_url "https://game.intqwq.com/api/health" || die "Public AlgoQuest did not become healthy through Bridge."
wait_for_url "https://intqwq.com/" || die "Public intqwq.com did not become healthy through Bridge."

log "Deploying intqwq.com as an independent origin on 127.0.0.1:18082"
bash "${intqwq_root}/deploy/pi/bootstrap-ubuntu.sh"
wait_for_url "http://127.0.0.1:18082/healthz" || die "The intqwq.com origin is not healthy."
bash "${bridge_root}/deploy/pi/status.sh"
wait_for_url "https://intqwq.com/" || die "Public intqwq.com failed after origin migration."

log "Disabling the obsolete service that coupled intqwq.com to AlgoQuest"
systemctl disable --now intqwq-shared.service 2>/dev/null || true

confirm "intqwq.com is independent. The next phase briefly stops AlgoQuest API and Judge writes, creates the final backup, and moves AlgoQuest to port 18081." "FREEZE-WRITES"

log "Freezing AlgoQuest writes and recording durable row counts"
compose_algoquest stop api judge judge-worker
writes_frozen=1
query_counts "${backup_dir}/counts.before.csv"
database_dump "${backup_dir}/algoquest-final.dump"
package_and_copy_backup "final"

log "Deploying AlgoQuest while preserving PostgreSQL volume ${aq_db_volume}"
bash "${algoquest_root}/deploy/pi/bootstrap-ubuntu.sh"
writes_frozen=0
bash "${algoquest_root}/deploy/pi/status.sh"
wait_for_url "http://127.0.0.1:18081/healthz" || die "The AlgoQuest private origin is not healthy."
wait_for_url "http://127.0.0.1:18081/api/health" || die "The AlgoQuest private API is not healthy."
record_database_mount "${backup_dir}/database-mount.after.txt"
query_counts "${backup_dir}/counts.after.csv"
verify_counts_not_lower

log "Running final Bridge and public-route checks"
bash "${bridge_root}/deploy/pi/status.sh"
wait_for_url "https://game.intqwq.com/api/health" || die "Public AlgoQuest is unhealthy."
wait_for_url "https://game.intqwq.com/" || die "Public AlgoQuest web is unhealthy."
wait_for_url "https://intqwq.com/" || die "Public intqwq.com is unhealthy."

{
  printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'algoquest_root=%s\n' "${algoquest_root}"
  printf 'intqwq_root=%s\n' "${intqwq_root}"
  printf 'bridge_root=%s\n' "${bridge_root}"
  printf 'postgres_volume=%s\n' "${aq_db_volume}"
  printf 'edge_port=%s\n' "${edge_port}"
} > "${backup_dir}/migration.completed.txt"
package_and_copy_backup "completed"

if [[ "${retire_legacy}" == "1" ]]; then
  confirm "Automated checks passed. Confirm existing-account data and a real Judge submission in the browser before retiring legacy tunnels." "RETIRE-LEGACY"
  systemctl disable --now algoquest-cloudflared.service 2>/dev/null || true
  docker rm -f intqwq-cloudflared 2>/dev/null || true
  log "Legacy tunnel processes retired. Credentials and backups were retained."
else
  log "Legacy tunnel processes were intentionally left running"
  printf 'After browser verification, retire them with:\n'
  printf '  sudo systemctl disable --now algoquest-cloudflared.service\n'
  printf '  sudo docker rm -f intqwq-cloudflared 2>/dev/null || true\n'
fi

log "Migration checks passed"
printf 'Backup directory: %s\n' "${backup_dir}"
printf 'Backup archive:   %s\n' "${backup_archive}"
printf 'Next: sign in with an existing account, verify progress/drafts/submissions, and run one real Judge submission.\n'
