#!/usr/bin/env bash
set -euo pipefail

# Backup Immich data to an external destination (e.g. a USB hard disk).
#
# Usage:
#   ./immich/backup.sh [--stop] [--dry-run] <destination-directory>
#   BACKUP_DEST=/mnt/backup ./immich/backup.sh [--stop] [--dry-run]
#
# What is backed up:
#   - Photo/video library (UPLOAD_LOCATION from immich/.env)
#   - PostgreSQL database dump (hot backup via pg_dumpall)
#   - immich/.env and immich/docker-compose.yml
#
# With --stop, Immich services are stopped first so the raw database data
# directory can be copied as well (cold backup). Services are restarted
# automatically after the copy.
#
# With --dry-run, no files are copied and no containers are touched; the
# planned actions are printed instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_command rsync
require_docker
require_env

usage() {
  cat <<EOF
Usage: $(basename "$0") [--stop] [--dry-run] <destination-directory>
   or: BACKUP_DEST=<path> $(basename "$0") [--stop] [--dry-run]

Options:
  --stop       Stop Immich before copying and restart it afterwards.
  --dry-run    Show what would be done without making changes.
  -h, --help   Show this help message.

The destination directory is created if it does not exist. Each run creates
a timestamped sub-folder: immich-backup-YYYYMMDD-HHMMSS.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
STOP_FLAG=false
DRY_RUN=false
DEST_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop)
      STOP_FLAG=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "${DEST_ARG}" ]]; then
        echo "ERROR: only one destination directory is allowed" >&2
        usage >&2
        exit 1
      fi
      DEST_ARG="$1"
      shift
      ;;
  esac
done

if [[ -z "${DEST_ARG}" ]]; then
  if [[ -n "${BACKUP_DEST:-}" ]]; then
    DEST_ARG="${BACKUP_DEST}"
  else
    echo "ERROR: backup destination not provided." >&2
    usage >&2
    exit 1
  fi
fi

# Resolve the destination before changing directories so relative paths are
# interpreted from wherever the user ran the script.
if [[ "${DRY_RUN}" == true ]]; then
  DEST="${DEST_ARG}"
else
  mkdir -p "${DEST_ARG}"
  DEST="$(realpath -m "${DEST_ARG}" 2>/dev/null || readlink -f "${DEST_ARG}")"
fi

cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Read required values from .env
# ---------------------------------------------------------------------------
get_env_var() {
  local key="$1"
  grep -E "^${key}=" .env | cut -d= -f2-
}

UPLOAD_LOCATION="$(get_env_var UPLOAD_LOCATION)"
DB_DATA_LOCATION="$(get_env_var DB_DATA_LOCATION)"
DB_USERNAME="$(get_env_var DB_USERNAME)"
DB_PASSWORD="$(get_env_var DB_PASSWORD)"

: "${UPLOAD_LOCATION:?UPLOAD_LOCATION must be set in .env}"
: "${DB_DATA_LOCATION:?DB_DATA_LOCATION must be set in .env}"
: "${DB_USERNAME:?DB_USERNAME must be set in .env}"
: "${DB_PASSWORD:?DB_PASSWORD must be set in .env}"

ABS_UPLOAD="$(realpath -m "${UPLOAD_LOCATION}" 2>/dev/null || readlink -f "${UPLOAD_LOCATION}")"
ABS_DB_DATA="$(realpath -m "${DB_DATA_LOCATION}" 2>/dev/null || readlink -f "${DB_DATA_LOCATION}")"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${DEST}/immich-backup-${TIMESTAMP}"
DB_DIR="${RUN_DIR}/db"
LIB_DIR="${RUN_DIR}/library"
CONFIG_DIR="${RUN_DIR}/config"

# ---------------------------------------------------------------------------
# Backup helpers
# ---------------------------------------------------------------------------
run_or_dry() {
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

create_backup_dirs() {
  if [[ "${DRY_RUN}" != true ]]; then
    mkdir -p "${DB_DIR}" "${LIB_DIR}" "${CONFIG_DIR}"
  fi
}

dump_database() {
  echo "[backup] Dumping PostgreSQL database (hot backup)..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[dry-run] compose exec -T -e PGPASSWORD='***' database pg_dumpall -c -U '${DB_USERNAME}' > '${DB_DIR}/immich.sql'"
  else
    compose exec -T -e PGPASSWORD="${DB_PASSWORD}" database pg_dumpall -c -U "${DB_USERNAME}" > "${DB_DIR}/immich.sql"
    if [[ ! -s "${DB_DIR}/immich.sql" ]]; then
      echo "ERROR: database dump is empty or failed." >&2
      exit 1
    fi
  fi
}

copy_database_files() {
  echo "[backup] Copying raw database data directory..."
  run_or_dry rsync -a --delete "${ABS_DB_DATA}/" "${DB_DIR}/data/"
}

copy_library() {
  echo "[backup] Syncing photo/video library..."
  run_or_dry rsync -a --delete "${ABS_UPLOAD}/" "${LIB_DIR}/"
}

copy_config() {
  echo "[backup] Copying configuration files..."
  run_or_dry cp -a .env docker-compose.yml "${CONFIG_DIR}/"
  if [[ "${DRY_RUN}" != true ]]; then
    chmod 600 "${CONFIG_DIR}/.env" 2>/dev/null || true
  fi
}

write_info() {
  if [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi

  cat > "${RUN_DIR}/backup-info.txt" <<EOF
MemoriQ / Immich backup
------------------------
Created: $(date -Iseconds)
Immich version: $(get_env_var IMMICH_VERSION)
Source upload location: ${ABS_UPLOAD}
Source database data:   ${ABS_DB_DATA}
Backup mode: $([[ "${STOP_FLAG}" == true ]] && echo "cold (services stopped)" || echo "hot (database dumped)")
EOF
}

# ---------------------------------------------------------------------------
# Run the backup
# ---------------------------------------------------------------------------
NEEDS_RESTART=false

restart_on_exit() {
  if [[ "${STOP_FLAG}" == true && "${NEEDS_RESTART}" == true ]]; then
    if [[ "${DRY_RUN}" == true ]]; then
      echo "[dry-run] would restart Immich services on exit"
    else
      echo "[backup] Restarting Immich services after early exit..."
      compose up -d --wait || true
    fi
  fi
}
trap restart_on_exit EXIT

echo "[backup] Destination: ${RUN_DIR}"

create_backup_dirs

if [[ "${STOP_FLAG}" == true ]]; then
  echo "[backup] Stopping Immich services for cold backup..."
  run_or_dry compose stop
  if [[ "${DRY_RUN}" != true ]]; then
    NEEDS_RESTART=true
  fi
fi

if [[ "${STOP_FLAG}" == true ]]; then
  copy_database_files
else
  dump_database
fi

copy_library
copy_config
write_info

if [[ "${STOP_FLAG}" == true ]]; then
  echo "[backup] Starting Immich services..."
  run_or_dry compose up -d --wait
  NEEDS_RESTART=false
  if [[ "${DRY_RUN}" != true ]]; then
    wait_for_immich_api || true
  fi
fi

if [[ "${DRY_RUN}" == true ]]; then
  echo "[backup] Dry-run finished. Backup would be created at: ${RUN_DIR}"
else
  echo "[backup] Backup complete: ${RUN_DIR}"
  du -sh "${RUN_DIR}" 2>/dev/null || true
fi
