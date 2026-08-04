#!/usr/bin/env bash
set -euo pipefail

# Migrate Google Photos into Immich from Google Takeout ZIP file(s).
#
# Usage:
#   ./immich/migrate-from-google-photos.sh
#
# This script will:
#   1. Check that Immich is running locally.
#   2. Download immich-go (a community migration tool) to a local cache.
#   3. Obtain an Immich API key automatically from admin credentials, or reuse a
#      previously cached key. You can also provide one manually via IMMICH_API_KEY.
#   4. Extract the ZIP(s) into a temporary staging directory.
#   5. Run a dry-run first, then import photos, videos, albums, dates, and GPS.
#
# Google Takeout:
#   - Request an export at https://takeout.google.com for "Google Photos" only.
#   - Choose ZIP, 50 GB per archive, and download all parts.
#   - Provide the ZIP file(s) to this script. Wildcards are supported.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./libs/migrate-lib.sh

migrate_require_commands

usage() {
  cat <<EOF
Usage: $(basename "$0")

Interactively migrate Google Photos Takeout ZIP archives into the local Immich server.

Environment variables (optional):
  IMMICH_API_KEY    Your Immich API key (skips auto-creation and caching).
  TAKEOUT_ZIP       Path to one or more Takeout ZIP files, wildcards allowed.
                    Examples:
                      /mnt/disk/takeout-20250101.zip
                      /mnt/disk/takeout-*.zip
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  usage
  exit 0
fi

prepare_migration

TAKEOUT_FILES=( $(prompt_zip_files "TAKEOUT_ZIP" "Google Takeout ZIP file(s)" "/mnt/disk/takeout-*.zip") )
IMMICH_API_KEY="$(ensure_api_key "Google Photos migration")"

SYNC_ALBUMS="true"
INCLUDE_PARTNER="true"
INCLUDE_ARCHIVED="true"
INCLUDE_TRASHED="false"
INCLUDE_UNMATCHED="false"
CONCURRENT_TASKS="4"

if prompt_yes_no "Recreate Google Photos albums in Immich?" "y"; then
  SYNC_ALBUMS="true"
else
  SYNC_ALBUMS="false"
fi

if prompt_yes_no "Include photos shared by a partner?" "y"; then
  INCLUDE_PARTNER="true"
else
  INCLUDE_PARTNER="false"
fi

if prompt_yes_no "Include archived photos?" "y"; then
  INCLUDE_ARCHIVED="true"
else
  INCLUDE_ARCHIVED="false"
fi

if prompt_yes_no "Include photos that were in Google Photos trash?" "n"; then
  INCLUDE_TRASHED="true"
fi

if prompt_yes_no "Import files that have no matching metadata JSON?" "n"; then
  INCLUDE_UNMATCHED="true"
fi

read -rp "Concurrent upload tasks (1-12, default 4): " input_concurrency
if [[ "${input_concurrency}" =~ ^[0-9]+$ ]] && [ "${input_concurrency}" -ge 1 ] && [ "${input_concurrency}" -le 12 ]; then
  CONCURRENT_TASKS="${input_concurrency}"
fi

# Create a temporary staging directory and extract all zips.
STAGING_DIR="${MIGRATE_REPO_ROOT}/data/.cache/immich-go/google-photos-staging-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${STAGING_DIR}"

echo ""
echo "[migrate] Extracting ${#TAKEOUT_FILES[@]} Takeout archive(s) to ${STAGING_DIR}..."
for zip in "${TAKEOUT_FILES[@]}"; do
  echo "  - $(basename "${zip}")"
  unzip -q "${zip}" -d "${STAGING_DIR}"
done

# Locate the Google Photos folder inside the extracted takeout.
GOOGLE_PHOTOS_DIR=""
GOOGLE_PHOTOS_DIR="$(find "${STAGING_DIR}" -maxdepth 3 -type d -name 'Google Photos' | head -n1)"

TAKEOUT_ROOT="${STAGING_DIR}"
if [ -n "${GOOGLE_PHOTOS_DIR}" ]; then
  TAKEOUT_ROOT="$(dirname "${GOOGLE_PHOTOS_DIR}")"
  echo "[migrate] Found Google Photos folder: ${GOOGLE_PHOTOS_DIR}"
else
  echo "[migrate] No 'Google Photos' folder found; using staging root: ${STAGING_DIR}"
fi

# Build the base command array.
cmd=(
  "${IMMICH_GO_BIN}"
  upload
  from-google-photos
  --sync-albums="${SYNC_ALBUMS}"
  --include-partner="${INCLUDE_PARTNER}"
  --include-archived="${INCLUDE_ARCHIVED}"
  --include-trashed="${INCLUDE_TRASHED}"
  --include-unmatched="${INCLUDE_UNMATCHED}"
  --concurrent-tasks="${CONCURRENT_TASKS}"
  --manage-raw-jpeg=StackCoverRaw
  --manage-burst=Stack
  --session-tag
  --tag="Source/GooglePhotos"
  --tag="Migration/$(date +%Y-%m-%d)"
  "${TAKEOUT_ROOT}"
)

run_migration "${STAGING_DIR}" "${cmd[@]}"

echo ""
echo "[migrate] Import complete."
echo "[migrate] Next steps:"
echo "  1. Spot-check a few photos in Immich for correct date, location, and albums."
echo "  2. Keep your Takeout ZIP files until you are confident the migration is solid."
echo "  3. Run face detection from Immich Administration -> Jobs if desired."

cleanup_staging "${STAGING_DIR}"
