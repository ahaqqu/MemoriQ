#!/usr/bin/env bash
set -euo pipefail

# Migrate iCloud Photos into Immich from iCloud data export ZIP file(s).
#
# Usage:
#   ./immich/migrate-from-icloud.sh
#
# This script will:
#   1. Check that Immich is running locally.
#   2. Download immich-go (a community migration tool) to a local cache.
#   3. Obtain an Immich API key automatically from admin credentials, or reuse a
#      previously cached key. You can also provide one manually via IMMICH_API_KEY.
#   4. Extract the ZIP(s) into a temporary staging directory.
#   5. Run a dry-run first, then import photos, videos, albums, and dates.
#
# iCloud data export:
#   - Request an export at https://privacy.apple.com for "iCloud Photos".
#   - Download all parts.
#   - Provide the ZIP file(s) to this script. Wildcards are supported.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./libs/migrate-lib.sh

migrate_require_commands

usage() {
  cat <<EOF
Usage: $(basename "$0")

Interactively migrate iCloud Photos export ZIP archives into the local Immich server.

Environment variables (optional):
  IMMICH_API_KEY    Your Immich API key (skips auto-creation and caching).
  ICLOUD_ZIP        Path to one or more iCloud export ZIP files, wildcards allowed.
                    Examples:
                      /mnt/disk/icloud-export.zip
                      /mnt/disk/icloud-*.zip
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  usage
  exit 0
fi

prepare_migration

ICLOUD_FILES=( $(prompt_zip_files "ICLOUD_ZIP" "iCloud Photos export ZIP file(s)" "/mnt/disk/icloud-*.zip") )
IMMICH_API_KEY="$(ensure_api_key "iCloud Photos migration")"

IMPORT_MEMORIES="false"
CONCURRENT_TASKS="4"

if prompt_yes_no "Import iCloud memories as albums?" "n"; then
  IMPORT_MEMORIES="true"
fi

read -rp "Concurrent upload tasks (1-12, default 4): " input_concurrency
if [[ "${input_concurrency}" =~ ^[0-9]+$ ]] && [ "${input_concurrency}" -ge 1 ] && [ "${input_concurrency}" -le 12 ]; then
  CONCURRENT_TASKS="${input_concurrency}"
fi

# Create a temporary staging directory and extract all zips.
STAGING_DIR="${MIGRATE_REPO_ROOT}/data/.cache/immich-go/icloud-staging-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${STAGING_DIR}"

echo ""
echo "[migrate] Extracting ${#ICLOUD_FILES[@]} iCloud export archive(s) to ${STAGING_DIR}..."
for zip in "${ICLOUD_FILES[@]}"; do
  echo "  - $(basename "${zip}")"
  unzip -q "${zip}" -d "${STAGING_DIR}"
done

ICLOUD_ROOT="${STAGING_DIR}"

# Build the base command array.
cmd=(
  "${IMMICH_GO_BIN}"
  upload
  from-icloud
  --memories="${IMPORT_MEMORIES}"
  --concurrent-tasks="${CONCURRENT_TASKS}"
  --manage-heic-jpeg=StackCoverJPG
  --manage-burst=Stack
  --session-tag
  --tag="Source/iCloud"
  --tag="Migration/$(date +%Y-%m-%d)"
  "${ICLOUD_ROOT}"
)

run_migration "${STAGING_DIR}" "${cmd[@]}"

echo ""
echo "[migrate] Import complete."
echo "[migrate] Next steps:"
echo "  1. Spot-check a few photos in Immich for correct date and albums."
echo "  2. Keep your iCloud export ZIP files until you are confident the migration is solid."
echo "  3. Run face detection from Immich Administration -> Jobs if desired."

cleanup_staging "${STAGING_DIR}"
