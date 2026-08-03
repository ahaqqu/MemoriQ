#!/usr/bin/env bash
set -euo pipefail

# Backup Immich data to an external destination (e.g. a USB hard disk).
#
# Usage:
#   ./immich/backup.sh <destination-directory>
#
# What is backed up:
#   - Photo/video library (UPLOAD_LOCATION from immich/.env)
#   - PostgreSQL database dump (hot backup via pg_dumpall)
#   - immich/.env and immich/docker-compose.yml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_command rsync
require_docker
require_env

usage() {
  cat <<EOF
Usage: $(basename "$0") <destination-directory>

The destination directory is created if it does not exist. Each run creates
a timestamped sub-folder: immich-backup-YYYYMMDD-HHMMSS.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "ERROR: exactly one destination directory is required" >&2
  usage >&2
  exit 1
fi

DEST_ARG="$1"

if [[ -z "${DEST_ARG}" ]]; then
  echo "ERROR: backup destination not provided." >&2
  usage >&2
  exit 1
fi

# Resolve the destination before changing directories so relative paths are
# interpreted from wherever the user ran the script.
mkdir -p "${DEST_ARG}"
DEST="$(realpath -m "${DEST_ARG}" 2>/dev/null || readlink -f "${DEST_ARG}")"

cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Read required values from .env
# ---------------------------------------------------------------------------
get_env_var() {
  local key="$1"
  grep -E "^${key}=" .env | cut -d= -f2-
}

UPLOAD_LOCATION="$(get_env_var UPLOAD_LOCATION)"
DB_USERNAME="$(get_env_var DB_USERNAME)"
DB_PASSWORD="$(get_env_var DB_PASSWORD)"

: "${UPLOAD_LOCATION:?UPLOAD_LOCATION must be set in .env}"
: "${DB_USERNAME:?DB_USERNAME must be set in .env}"
: "${DB_PASSWORD:?DB_PASSWORD must be set in .env}"

ABS_UPLOAD="$(realpath -m "${UPLOAD_LOCATION}" 2>/dev/null || readlink -f "${UPLOAD_LOCATION}")"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${DEST}/immich-backup-${TIMESTAMP}"
DB_DIR="${RUN_DIR}/db"
LIB_DIR="${RUN_DIR}/library"
CONFIG_DIR="${RUN_DIR}/config"

# ---------------------------------------------------------------------------
# Backup helpers
# ---------------------------------------------------------------------------
dump_database() {
  echo "[backup] Dumping PostgreSQL database..."
  compose exec -T -e PGPASSWORD="${DB_PASSWORD}" database pg_dumpall -c -U "${DB_USERNAME}" > "${DB_DIR}/immich.sql"
  if [[ ! -s "${DB_DIR}/immich.sql" ]]; then
    echo "ERROR: database dump is empty or failed." >&2
    exit 1
  fi
}

copy_library() {
  echo "[backup] Syncing photo/video library..."
  rsync -a --delete "${ABS_UPLOAD}/" "${LIB_DIR}/"
}

copy_config() {
  echo "[backup] Copying configuration files..."
  cp -a .env compose/docker-compose.yml "${CONFIG_DIR}/"
  chmod 600 "${CONFIG_DIR}/.env" 2>/dev/null || true
}

write_info() {
  cat > "${RUN_DIR}/backup-info.txt" <<EOF
MemoriQ / Immich backup
------------------------
Created: $(date -Iseconds)
Immich version: $(get_env_var IMMICH_VERSION)
Source upload location: ${ABS_UPLOAD}
EOF
}

# ---------------------------------------------------------------------------
# Run the backup
# ---------------------------------------------------------------------------
echo "[backup] Destination: ${RUN_DIR}"

mkdir -p "${DB_DIR}" "${LIB_DIR}" "${CONFIG_DIR}"

dump_database
copy_library
copy_config
write_info

echo "[backup] Backup complete: ${RUN_DIR}"
du -sh "${RUN_DIR}" 2>/dev/null || true
