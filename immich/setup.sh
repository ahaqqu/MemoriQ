#!/usr/bin/env bash
set -euo pipefail

# Idempotent setup script for Immich.
# Run this from the repository root: ./immich/setup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SCRIPT_DIR}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is required but not installed."
    exit 1
  fi
}

generate_password() {
  # Use only hex characters so the password is safe for sed substitutions.
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | base64 | tr -dc 'a-f0-9' | head -c 32
  fi
}

require_command docker

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: Docker Compose plugin is required."
  exit 1
fi

if [ ! -f .env ]; then
  echo "[setup] Creating immich/.env from .env.example..."
  DB_PASSWORD="$(generate_password)"
  sed -e "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" \
      -e "s#^TZ=.*#TZ=$(cat /etc/timezone 2>/dev/null || echo 'UTC')#" \
      .env.example > .env
  chmod 600 .env
  echo "[setup] Generated .env with a random database password."
else
  echo "[setup] .env already exists; leaving it unchanged."
fi

UPLOAD_LOCATION="$(grep '^UPLOAD_LOCATION=' .env | cut -d= -f2-)"
DB_DATA_LOCATION="$(grep '^DB_DATA_LOCATION=' .env | cut -d= -f2-)"

mkdir -p "${UPLOAD_LOCATION}"
mkdir -p "${DB_DATA_LOCATION}"

echo "[setup] Ensured data directories exist:"
echo "  photos: ${UPLOAD_LOCATION}"
echo "  db:     ${DB_DATA_LOCATION}"

echo "[setup] Pulling Immich images..."
docker compose pull

echo "[setup] Starting Immich services..."
docker compose up -d

echo ""
echo "[setup] Immich is starting."
echo "  Web UI: http://localhost:2283"
echo "  Data:   ${REPO_ROOT}/data/immich"
echo ""
echo "First-time login: create the admin account at http://localhost:2283/auth/register"
