#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for the Immich lifecycle scripts.
# This file is meant to be sourced, not executed directly.

IMMICH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${IMMICH_DIR}/.." && pwd)"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}

require_docker() {
  require_command docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose plugin is required." >&2
    exit 1
  fi
}

require_env() {
  if [ ! -f "${IMMICH_DIR}/.env" ]; then
    echo "ERROR: .env not found. Run ./immich/setup.sh first." >&2
    exit 1
  fi
}

compose() {
  docker compose -f "${IMMICH_DIR}/docker-compose.yml" --env-file "${IMMICH_DIR}/.env" "$@"
}

generate_password() {
  # Use only hex characters so the password is safe for sed substitutions.
  local pw
  if command -v openssl >/dev/null 2>&1; then
    pw=$(openssl rand -hex 32)
  else
    pw=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 64)
  fi
  if [ "${#pw}" -lt 32 ]; then
    echo "ERROR: failed to generate a strong database password." >&2
    exit 1
  fi
  printf '%s' "$pw"
}

detect_timezone() {
  local tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  fi
  if [ -z "$tz" ] && [ -f /etc/timezone ]; then
    tz=$(head -n1 /etc/timezone)
  fi
  printf '%s' "${tz:-UTC}"
}

ensure_data_dir_permissions() {
  local path="$1"
  local mode="$2"
  mkdir -p "$path"

  # If we own the directory, set a restrictive mode. Existing directories that
  # are already owned by a container user (e.g. postgres) are left alone.
  if [ -d "$path" ] && [ "$(stat -c '%u' "$path" 2>/dev/null || echo 65535)" -eq "$(id -u)" ]; then
    chmod "$mode" "$path" || true
  fi

  # If the path lives under the default git-ignored data tree, lock down the
  # parent directories as well without touching user-defined custom paths.
  if [ "${path#${REPO_ROOT}/data/}" != "$path" ]; then
    local parent="${REPO_ROOT}/data"
    while [ "$parent" != "${REPO_ROOT}" ]; do
      if [ -d "$parent" ] && [ "$(stat -c '%u' "$parent" 2>/dev/null || echo 65535)" -eq "$(id -u)" ]; then
        chmod 700 "$parent" 2>/dev/null || true
      fi
      parent="$(dirname "$parent")"
    done
  fi
}

wait_for_immich_api() {
  local url="http://127.0.0.1:2283/api/server/ping"
  if ! command -v curl >/dev/null 2>&1; then
    echo "[setup] curl not available; skipping live API health check."
    return 0
  fi

  echo "[setup] Waiting for Immich API to respond..."
  local i
  for i in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "[setup] Immich API is ready."
      return 0
    fi
    sleep 2
  done

  echo "WARNING: Immich API did not respond in time. The containers may still be starting." >&2
  return 1
}
