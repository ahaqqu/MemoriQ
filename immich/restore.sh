#!/usr/bin/env bash
set -euo pipefail

# Restore Immich from a backup created by backup.sh.
#
# Usage:
#   ./immich/restore.sh [--yes] <backup-run-directory>
#
# The backup run directory is the timestamped folder produced by backup.sh, e.g.:
#   /mnt/usb/immich-backup-20260804-120000
#
# This script will:
#   1. Stop all Immich services.
#   2. Back up the current immich/.env and immich/docker-compose.yml.
#   3. Restore the backed-up .env and docker-compose.yml.
#   4. Restore the photo/video library to UPLOAD_LOCATION.
#   5. Wipe and recreate the PostgreSQL data directory and replay the SQL dump.
#   6. Start all Immich services.
#
# WARNING: this is destructive. Current library and database will be replaced.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_command rsync
require_docker
require_env

AUTO_YES=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] <backup-run-directory>

Restores Immich from a backup created by backup.sh.

Options:
  --yes   Skip the destructive-operation confirmation.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      AUTO_YES=true
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
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  echo "ERROR: exactly one backup run directory is required" >&2
  usage >&2
  exit 1
fi

BACKUP_RUN="$1"
if [[ ! -d "${BACKUP_RUN}" ]]; then
  echo "ERROR: backup directory does not exist: ${BACKUP_RUN}" >&2
  exit 1
fi

BACKUP_RUN="$(realpath -m "${BACKUP_RUN}" 2>/dev/null || readlink -f "${BACKUP_RUN}")"

# ---------------------------------------------------------------------------
# Validate backup contents
# ---------------------------------------------------------------------------
for item in library db/immich.sql config/.env config/docker-compose.yml; do
  if [[ ! -e "${BACKUP_RUN}/${item}" ]]; then
    echo "ERROR: backup is missing expected item: ${item}" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Read current destination paths for the confirmation prompt
# ---------------------------------------------------------------------------
cd "${SCRIPT_DIR}"

get_env_var() {
  local key="$1"
  grep -E "^${key}=" .env | cut -d= -f2-
}

UPLOAD_LOCATION="$(get_env_var UPLOAD_LOCATION)"
DB_DATA_LOCATION="$(get_env_var DB_DATA_LOCATION)"

: "${UPLOAD_LOCATION:?UPLOAD_LOCATION must be set in .env}"
: "${DB_DATA_LOCATION:?DB_DATA_LOCATION must be set in .env}"

ABS_UPLOAD="$(realpath -m "${UPLOAD_LOCATION}" 2>/dev/null || readlink -f "${UPLOAD_LOCATION}")"
ABS_DB="$(realpath -m "${DB_DATA_LOCATION}" 2>/dev/null || readlink -f "${DB_DATA_LOCATION}")"

# ---------------------------------------------------------------------------
# Confirm destructive operation
# ---------------------------------------------------------------------------
if [[ "${AUTO_YES}" != "true" ]]; then
  cat <<EOF >&2

WARNING: this will DESTROY the current Immich data and replace it with:

  Backup: ${BACKUP_RUN}
  Library target: ${ABS_UPLOAD}
  Database target: ${ABS_DB}
  Config target: ${SCRIPT_DIR}/.env and ${SCRIPT_DIR}/docker-compose.yml

A copy of the current config files will be saved first.

Type "restore" to continue:
EOF
  read -r confirmation
  if [[ "${confirmation}" != "restore" ]]; then
    echo "Restore cancelled." >&2
    exit 1
  fi
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Stop services before touching data
# ---------------------------------------------------------------------------
echo "[restore] Stopping Immich services..."
compose down

# ---------------------------------------------------------------------------
# Back up current config, then restore backed-up config
# ---------------------------------------------------------------------------
echo "[restore] Saving current config to .restore-backup-${TIMESTAMP}..."
cp -a .env ".env.restore-backup-${TIMESTAMP}" || true
cp -a docker-compose.yml "docker-compose.yml.restore-backup-${TIMESTAMP}" || true

echo "[restore] Restoring config files from backup..."
cp -a "${BACKUP_RUN}/config/.env" .env
chmod 600 .env
cp -a "${BACKUP_RUN}/config/docker-compose.yml" docker-compose.yml

# ---------------------------------------------------------------------------
# Re-read required values from the restored .env
# ---------------------------------------------------------------------------
UPLOAD_LOCATION="$(get_env_var UPLOAD_LOCATION)"
DB_DATA_LOCATION="$(get_env_var DB_DATA_LOCATION)"
DB_USERNAME="$(get_env_var DB_USERNAME)"
DB_PASSWORD="$(get_env_var DB_PASSWORD)"
DB_DATABASE_NAME="$(get_env_var DB_DATABASE_NAME)"

: "${UPLOAD_LOCATION:?UPLOAD_LOCATION must be set in .env}"
: "${DB_DATA_LOCATION:?DB_DATA_LOCATION must be set in .env}"
: "${DB_USERNAME:?DB_USERNAME must be set in .env}"
: "${DB_PASSWORD:?DB_PASSWORD must be set in .env}"
: "${DB_DATABASE_NAME:?DB_DATABASE_NAME must be set in .env}"

ABS_UPLOAD="$(realpath -m "${UPLOAD_LOCATION}" 2>/dev/null || readlink -f "${UPLOAD_LOCATION}")"
ABS_DB="$(realpath -m "${DB_DATA_LOCATION}" 2>/dev/null || readlink -f "${DB_DATA_LOCATION}")"

# ---------------------------------------------------------------------------
# Restore library
# ---------------------------------------------------------------------------
echo "[restore] Restoring photo/video library to ${ABS_UPLOAD}..."
mkdir -p "${ABS_UPLOAD}"
rsync -a --delete "${BACKUP_RUN}/library/" "${ABS_UPLOAD}/"

# ---------------------------------------------------------------------------
# Restore database
# ---------------------------------------------------------------------------
wipe_db_data() {
  if [[ ! -d "${ABS_DB}" ]]; then
    mkdir -p "${ABS_DB}"
    return 0
  fi

  local owner_uid
  owner_uid="$(stat -c '%u' "${ABS_DB}" 2>/dev/null || echo 65535)"

  if [[ "${owner_uid}" -eq "$(id -u)" ]]; then
    echo "[restore] Wiping existing database data directory..."
    rm -rf "${ABS_DB}"/* "${ABS_DB}"/.[^.]* 2>/dev/null || true
  else
    echo "[restore] Database directory is owned by container user; using Docker to wipe it..."
    docker run --rm -v "${ABS_DB}:/pgdata" alpine rm -rf /pgdata
  fi

  mkdir -p "${ABS_DB}"
}

echo "[restore] Restoring PostgreSQL database..."
wipe_db_data

echo "[restore] Starting database container to initialize fresh data directory..."
compose up -d database

echo "[restore] Waiting for database to accept connections..."
ready=false
for i in $(seq 1 60); do
  if compose exec -T -e PGPASSWORD="${DB_PASSWORD}" database pg_isready -U "${DB_USERNAME}" -d postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done

if [[ "${ready}" != "true" ]]; then
  echo "ERROR: database did not become ready in time." >&2
  exit 1
fi

echo "[restore] Replaying SQL dump..."
compose exec -T -e PGPASSWORD="${DB_PASSWORD}" database psql -U "${DB_USERNAME}" -d postgres < "${BACKUP_RUN}/db/immich.sql"

# ---------------------------------------------------------------------------
# Start all services
# ---------------------------------------------------------------------------
echo "[restore] Starting all Immich services..."
compose up -d --wait

echo ""
echo "[restore] Restore complete."
echo "  Web UI: http://127.0.0.1:2283"
echo "  Library: ${ABS_UPLOAD}"
echo "  Config backup: ${SCRIPT_DIR}/.env.restore-backup-${TIMESTAMP}"
