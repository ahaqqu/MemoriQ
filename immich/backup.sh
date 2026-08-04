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
source "${SCRIPT_DIR}/libs/lib.sh"

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
UPLOAD_LOCATION="$(env_value UPLOAD_LOCATION)"
DB_USERNAME="$(env_value DB_USERNAME)"
DB_PASSWORD="$(env_value DB_PASSWORD)"

: "${UPLOAD_LOCATION:?UPLOAD_LOCATION must be set in .env}"
: "${DB_USERNAME:?DB_USERNAME must be set in .env}"
: "${DB_PASSWORD:?DB_PASSWORD must be set in .env}"

ABS_UPLOAD="$(realpath -m "${UPLOAD_LOCATION}" 2>/dev/null || readlink -f "${UPLOAD_LOCATION}")"

# Refuse to write the backup into the upload location; it would become part of
# the rsync source and recursively explode.
if [[ "${DEST}" == "${ABS_UPLOAD}"* ]]; then
  echo "ERROR: backup destination cannot be inside UPLOAD_LOCATION (${ABS_UPLOAD})." >&2
  exit 1
fi

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
  # Export the password in a subshell so the literal value never appears in
  # the docker compose exec command line (visible via ps).
  (
    export PGPASSWORD="${DB_PASSWORD}"
    compose exec -T -e PGPASSWORD database pg_dumpall -c -U "${DB_USERNAME}" > "${DB_DIR}/immich.sql"
  )
  if [[ ! -s "${DB_DIR}/immich.sql" ]]; then
    echo "ERROR: database dump is empty or failed." >&2
    exit 1
  fi
  chmod 600 "${DB_DIR}/immich.sql"
}

copy_library() {
  echo "[backup] Syncing photo/video library..."
  rsync -a --delete "${ABS_UPLOAD}/" "${LIB_DIR}/"
}

copy_config() {
  echo "[backup] Copying configuration files..."
  cp -a .env compose/docker-compose.yml "${CONFIG_DIR}/"
  chmod 600 "${CONFIG_DIR}/.env" "${CONFIG_DIR}/docker-compose.yml" 2>/dev/null || true
}

write_info() {
  cat > "${RUN_DIR}/backup-info.txt" <<EOF
MemoriQ / Immich backup
------------------------
Created: $(date -Iseconds)
Immich version: $(env_value IMMICH_VERSION)
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
chmod -R go-rwx "${RUN_DIR}" 2>/dev/null || true
du -sh "${RUN_DIR}" 2>/dev/null || true
