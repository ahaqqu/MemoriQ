#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run ./immich/setup.sh first."
  exit 1
fi

echo "[update] Pulling latest Immich images..."
docker compose pull

echo "[update] Recreating services with new images..."
docker compose up -d --force-recreate

echo "[update] Immich updated and restarted."
