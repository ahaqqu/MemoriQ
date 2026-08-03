#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./libs/lib.sh

require_docker

echo "[stop] Stopping Immich services..."
compose down

echo "[stop] Immich services stopped."
