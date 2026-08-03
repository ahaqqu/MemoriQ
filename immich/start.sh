#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./lib.sh

require_docker
require_env

echo "[start] Starting Immich services..."
compose up -d --wait

wait_for_immich_api || true

echo "[start] Immich is running at http://127.0.0.1:2283"
