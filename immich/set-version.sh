#!/usr/bin/env bash
set -euo pipefail

# Change the pinned Immich version in immich/.env and update the deployment.
# Usage: ./immich/set-version.sh v1.131.3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./libs/lib.sh

require_env

NEW_VERSION="${1:-}"
if [ -z "$NEW_VERSION" ]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 v1.131.3" >&2
  exit 1
fi

# Validate that the version looks like a semver tag to avoid accidental typos.
if [[ ! "$NEW_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "WARNING: version '$NEW_VERSION' does not look like a semver tag (e.g. v1.131.3)." >&2
  read -r -p "Continue anyway? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

current_version="$(env_value IMMICH_VERSION)"
echo "[set-version] Changing IMMICH_VERSION from '$current_version' to '$NEW_VERSION'."

# Avoid sed replacement issues by rewriting the line safely.
grep -v '^IMMICH_VERSION=' .env > .env.tmp
echo "IMMICH_VERSION=${NEW_VERSION}" >> .env.tmp
chmod 600 .env.tmp
mv -f .env.tmp .env

./update.sh
