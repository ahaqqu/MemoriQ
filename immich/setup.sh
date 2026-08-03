#!/usr/bin/env bash
set -euo pipefail

# Idempotent first-time setup script for Immich.
# Run this from the repository root: ./immich/setup.sh
#
# This script will:
#   1. Install Docker if it is missing.
#   2. Create immich/.env with a generated database password.
#   3. Create the required data directories with secure permissions.
#   4. Pull and start the Immich services.
#
# Re-running this script after .env exists is safe: it will only re-apply
# directory and permission checks and will not upgrade or restart services.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./libs/lib.sh

# --- 1. Ensure Docker is installed ---
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "[setup] Docker or the Docker Compose plugin is not installed."
  ./libs/install-docker.sh
fi
require_docker

# --- 2. Generate .env on first run only ---
if [ -f .env ]; then
  echo "[setup] .env already exists; leaving it unchanged."
  chmod 600 .env 2>/dev/null || true
else
  echo "[setup] Creating immich/.env from .env.example..."
  DB_PASSWORD="$(generate_password)"
  SYSTEM_TZ="$(detect_timezone)"

  sed -e "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" \
      -e "s#^TZ=.*#TZ=${SYSTEM_TZ}#" \
      .env.example > .env.tmp

  if [ "${#DB_PASSWORD}" -lt 32 ]; then
    echo "ERROR: generated database password is too short." >&2
    rm -f .env.tmp
    exit 1
  fi

  chmod 600 .env.tmp
  mv -f .env.tmp .env
  echo "[setup] Generated .env with a random database password."
fi

# --- 3. Read and validate required paths from .env ---
UPLOAD_LOCATION="$(grep '^UPLOAD_LOCATION=' .env | cut -d= -f2-)"
DB_DATA_LOCATION="$(grep '^DB_DATA_LOCATION=' .env | cut -d= -f2-)"

: "${UPLOAD_LOCATION:?UPLOAD_LOCATION must be set in .env}"
: "${DB_DATA_LOCATION:?DB_DATA_LOCATION must be set in .env}"

# --- 4. Ensure data directories exist with secure permissions ---
ensure_data_dir_permissions "${UPLOAD_LOCATION}" 750
ensure_data_dir_permissions "${DB_DATA_LOCATION}" 700

echo "[setup] Ensured data directories exist:"
echo "  photos: ${UPLOAD_LOCATION}"
echo "  db:     ${DB_DATA_LOCATION}"

# If .env already existed, we only re-applied permissions/directories above.
# Pull and start services only on the very first setup.
SETUP_FIRST_RUN=false
if [ -f .env.setup-done ]; then
  echo ""
  echo "[setup] Setup has already run once. Use ./immich/start.sh or ./immich/update.sh to control services."
else
  SETUP_FIRST_RUN=true
  echo "[setup] Pulling Immich images..."
  compose pull

  echo "[setup] Starting Immich services..."
  compose up -d --wait

  wait_for_immich_api || true

  touch .env.setup-done
  echo ""
  echo "[setup] Immich is ready."
fi

echo ""
echo "  Web UI: http://127.0.0.1:2283"
echo "  Data:   ${REPO_ROOT}/data/immich"
echo ""
echo "First-time login: create the admin account at http://127.0.0.1:2283/auth/register"

# --- Optional reverse proxy setup, offered once on first run ---
if [ "${SETUP_FIRST_RUN}" = true ] && [ -t 0 ]; then
  echo ""
  echo "[setup] You can also expose Immich securely over the internet via Tailscale Funnel."
  echo "        This is free, encrypted, and does not require router port forwarding."
  read -rp "        Set up Tailscale Funnel now? [y/N]: " answer
  case "${answer}" in
    [yY]|[yY][eE][sS])
      echo ""
      if [ -x "${SCRIPT_DIR}/setup-tailscale.sh" ]; then
        "${SCRIPT_DIR}/setup-tailscale.sh"
      else
        echo "ERROR: setup-tailscale.sh not found or not executable." >&2
        exit 1
      fi
      ;;
    *)
      echo "[setup] Skipped Tailscale Funnel setup. You can run it later with:"
      echo "        ./immich/reverse-proxy/setup.sh"
      ;;
  esac
fi
