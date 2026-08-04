#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./libs/lib.sh

require_docker
require_env

echo "[update] Pulling Immich images for version $(env_value IMMICH_VERSION)..."
compose pull

echo "[update] Recreating services with new images..."
compose up -d --wait

wait_for_immich_api || true

echo "[update] Immich updated and restarted at http://127.0.0.1:2283"
