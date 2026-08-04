#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for the Immich migration scripts (Google Photos, iCloud, etc.).
# This file is meant to be sourced, not executed directly.

MIGRATE_LIBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_IMMICH_DIR="$(cd "${MIGRATE_LIBS_DIR}/.." && pwd)"
MIGRATE_REPO_ROOT="$(cd "${MIGRATE_IMMICH_DIR}/.." && pwd)"

source "${MIGRATE_LIBS_DIR}/lib.sh"

IMMICH_GO_VERSION="v0.32.0"
IMMICH_GO_BIN="${MIGRATE_REPO_ROOT}/data/.cache/immich-go/immich-go-${IMMICH_GO_VERSION}"

SERVER_URL="http://127.0.0.1:2283"
API_KEY_CACHE_DIR="${MIGRATE_REPO_ROOT}/data/.cache/immich-go"
API_KEY_CACHE="${API_KEY_CACHE_DIR}/.api-key"

# ---------------------------------------------------------------------------
# Required host tools
# ---------------------------------------------------------------------------
migrate_require_commands() {
  require_command curl
  require_command tar
  require_command sha256sum
  require_command unzip
  require_command python3
}

# ---------------------------------------------------------------------------
# immich-go download and cache
# ---------------------------------------------------------------------------
get_arch_asset() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}" in
    Linux)
      case "${arch}" in
        x86_64) echo "immich-go_Linux_x86_64.tar.gz" ;;
        aarch64|arm64) echo "immich-go_Linux_arm64.tar.gz" ;;
        *) return 1 ;;
      esac
      ;;
    Darwin)
      case "${arch}" in
        x86_64) echo "immich-go_Darwin_x86_64.tar.gz" ;;
        aarch64|arm64) echo "immich-go_Darwin_arm64.tar.gz" ;;
        *) return 1 ;;
      esac
      ;;
    FreeBSD)
      case "${arch}" in
        x86_64|amd64) echo "immich-go_Freebsd_x86_64.tar.gz" ;;
        aarch64|arm64) echo "immich-go_Freebsd_arm64.tar.gz" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

download_immich_go() {
  local asset
  asset="$(get_arch_asset)" || {
    echo "ERROR: unsupported platform: $(uname -s) $(uname -m)" >&2
    echo "       immich-go binaries are available for Linux, macOS, and FreeBSD on x86_64/arm64." >&2
    exit 1
  }

  local download_url="https://github.com/simulot/immich-go/releases/download/${IMMICH_GO_VERSION}/${asset}"
  local checksums_url="https://github.com/simulot/immich-go/releases/download/${IMMICH_GO_VERSION}/checksums.txt"
  local tmp_dir="${MIGRATE_REPO_ROOT}/data/.cache/immich-go/tmp"
  local tarball="${tmp_dir}/${asset}"
  local checksums="${tmp_dir}/checksums.txt"

  echo "[migrate] Downloading immich-go ${IMMICH_GO_VERSION} for $(uname -s) $(uname -m)..."
  mkdir -p "${tmp_dir}"

  curl -fsSL --retry 3 --retry-delay 2 -o "${tarball}" "${download_url}"
  curl -fsSL --retry 3 --retry-delay 2 -o "${checksums}" "${checksums_url}"

  echo "[migrate] Verifying checksum..."
  local expected
  expected="$(grep "${asset}" "${checksums}" | awk '{print $1}')"
  if [ -z "${expected}" ]; then
    echo "ERROR: could not find checksum for ${asset} in downloaded checksums.txt" >&2
    rm -rf "${tmp_dir}"
    exit 1
  fi

  printf '%s  %s\n' "${expected}" "${tarball}" > "${tmp_dir}/sha256sum.txt"
  (cd "${tmp_dir}" && sha256sum -c sha256sum.txt) >/dev/null 2>&1 || {
    echo "ERROR: checksum verification failed for ${asset}" >&2
    rm -rf "${tmp_dir}"
    exit 1
  }

  echo "[migrate] Extracting immich-go..."
  tar -xzf "${tarball}" -C "${tmp_dir}"

  local extracted_bin
  extracted_bin="$(find "${tmp_dir}" -maxdepth 2 -type f -name 'immich-go' | head -n1)"
  if [ -z "${extracted_bin}" ]; then
    echo "ERROR: immich-go binary not found in extracted archive" >&2
    rm -rf "${tmp_dir}"
    exit 1
  fi

  mkdir -p "$(dirname "${IMMICH_GO_BIN}")"
  mv "${extracted_bin}" "${IMMICH_GO_BIN}"
  chmod +x "${IMMICH_GO_BIN}"
  rm -rf "${tmp_dir}"

  echo "[migrate] immich-go ready: ${IMMICH_GO_BIN}"
}

ensure_immich_go() {
  if [ ! -x "${IMMICH_GO_BIN}" ]; then
    download_immich_go
  fi
}

check_immich_running() {
  local url="${SERVER_URL}/api/server/ping"
  if ! curl -fsS "${url}" >/dev/null 2>&1; then
    echo "ERROR: Immich does not appear to be running at ${SERVER_URL}" >&2
    echo "       Start it first with: ./immich/start.sh" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# API key management: env var, cache, or auto-create from admin credentials
# ---------------------------------------------------------------------------
api_key_works() {
  local key="$1"
  local response
  response="$(curl -fsS -H "x-api-key: ${key}" "${SERVER_URL}/api/users/me" 2>/dev/null)" || return 1
  [ -n "${response}" ]
}

cache_api_key() {
  local key="$1"
  mkdir -p "${API_KEY_CACHE_DIR}"
  printf '%s' "${key}" > "${API_KEY_CACHE}"
  chmod 600 "${API_KEY_CACHE}"
}

read_cached_api_key() {
  if [ -f "${API_KEY_CACHE}" ]; then
    cat "${API_KEY_CACHE}"
  fi
}

json_field() {
  local json="$1"
  local field="$2"
  python3 -c "import sys,json; print(json.load(sys.stdin).get('${field}',''))" <<<"${json}"
}

prompt_admin_credentials() {
  local email password name
  echo ""
  echo "[migrate] Admin account credentials"
  echo "  For a fresh install, this will create the first admin user."
  echo "  For an existing install, this will log in as the admin."
  read -rp "  Admin email: " email
  read -rsp "  Admin password: " password
  echo ""
  read -rp "  Admin name (fresh installs only): " name
  printf '%s\t%s\t%s\n' "${email}" "${password}" "${name}"
}

auto_create_api_key() {
  local api_key_name="$1"
  local credentials email password name
  local signup_body signup_response
  local login_body login_response access_token
  local create_body create_response secret

  credentials="$(prompt_admin_credentials)"
  email="$(cut -f1 <<<"${credentials}")"
  password="$(cut -f2 <<<"${credentials}")"
  name="$(cut -f3 <<<"${credentials}")"

  # Try to create the first admin user. This only works before the admin page is closed.
  signup_body="$(python3 -c "import sys,json; print(json.dumps({'email':sys.argv[1],'password':sys.argv[2],'name':sys.argv[3]}))" "${email}" "${password}" "${name}")"
  echo "[migrate] Checking if admin sign-up is available..."
  signup_response="$(curl -fsS -X POST -H "Content-Type: application/json" -d "${signup_body}" "${SERVER_URL}/api/auth/admin-sign-up" 2>/dev/null || true)"
  if [ -n "${signup_response}" ] && [ "$(json_field "${signup_response}" "email")" = "${email}" ]; then
    echo "[migrate] Admin account created."
  fi

  # Log in to get an access token.
  login_body="$(python3 -c "import sys,json; print(json.dumps({'email':sys.argv[1],'password':sys.argv[2]}))" "${email}" "${password}")"
  echo "[migrate] Logging in as ${email}..."
  login_response="$(curl -fsS -X POST -H "Content-Type: application/json" -d "${login_body}" "${SERVER_URL}/api/auth/login" 2>/dev/null || true)"
  access_token="$(json_field "${login_response}" "accessToken")"
  if [ -z "${access_token}" ]; then
    echo "ERROR: login failed. Check your email and password." >&2
    echo "       If this is a fresh install, make sure you have not already closed admin registration." >&2
    return 1
  fi

  # Create an API key with full permissions for the migration.
  create_body="$(python3 -c "import json; print(json.dumps({'name':sys.argv[1],'permissions':['all']}))" "${api_key_name}")"
  echo "[migrate] Creating API key..."
  create_response="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -d "${create_body}" \
    "${SERVER_URL}/api/api-keys" 2>/dev/null || true)"
  secret="$(json_field "${create_response}" "secret")"
  if [ -z "${secret}" ]; then
    echo "ERROR: failed to create API key. Server response:" >&2
    echo "${create_response}" >&2
    return 1
  fi

  cache_api_key "${secret}"
  printf '%s' "${secret}"
}

ensure_api_key() {
  local api_key_name="${1:-Immich migration}"

  # 1. Environment override
  if [ -n "${IMMICH_API_KEY:-}" ]; then
    if api_key_works "${IMMICH_API_KEY}"; then
      printf '%s' "${IMMICH_API_KEY}"
      return 0
    fi
    echo "WARNING: the provided IMMICH_API_KEY does not work; trying other options." >&2
  fi

  # 2. Cached key
  local cached
  cached="$(read_cached_api_key)"
  if [ -n "${cached}" ] && api_key_works "${cached}"; then
    echo "[migrate] Using cached API key." >&2
    printf '%s' "${cached}"
    return 0
  fi

  # 3. Auto-create from admin credentials, with manual fallback
  echo ""
  echo "[migrate] An Immich API key is required to upload photos via the API."
  echo "          The script can create one for you using the admin account."
  if prompt_yes_no "Create API key automatically from admin credentials?" "y"; then
    local auto_key
    if auto_key="$(auto_create_api_key "${api_key_name}")"; then
      printf '%s' "${auto_key}"
      return 0
    fi
    echo "[migrate] Automatic API key creation failed. Falling back to manual entry." >&2
  fi

  prompt_api_key
}

prompt_api_key() {
  local key
  echo ""
  echo "[migrate] Immich API key"
  echo "  Create one in the Immich web UI:"
  echo "    1. Open ${SERVER_URL}"
  echo "    2. Click your avatar -> Account Settings -> API Keys"
  echo "    3. Create a new key and copy it here"
  read -rsp "  API key: " key
  echo ""

  if [ -z "${key}" ]; then
    echo "ERROR: API key is required." >&2
    exit 1
  fi

  cache_api_key "${key}"
  printf '%s' "${key}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer

  if [ "${default}" = "y" ]; then
    read -rp "${prompt} [Y/n]: " answer
    case "${answer}" in
      [nN]|[nN][oO]) return 1 ;;
      *) return 0 ;;
    esac
  else
    read -rp "${prompt} [y/N]: " answer
    case "${answer}" in
      [yY]|[yY][eE][sS]) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# ZIP archive prompting
# ---------------------------------------------------------------------------
prompt_zip_files() {
  local env_var="$1"
  local label="$2"
  local example="$3"
  local path

  if [ -n "${!env_var:-}" ]; then
    path="${!env_var}"
  else
    echo "" >&2
    echo "[migrate] ${label}" >&2
    echo "  Provide the path to one or more ZIP archives. Wildcards are supported." >&2
    echo "  Example: ${example}" >&2
    read -rp "  ${label}: " path
  fi

  if [ -z "${path}" ]; then
    echo "ERROR: ${label} path is required." >&2
    exit 1
  fi

  local matches=()
  shopt -s nullglob
  # Use compgen to expand the glob while preserving spaces in filenames.
  readarray -t matches < <(compgen -G "${path}")
  shopt -u nullglob

  if [ ${#matches[@]} -eq 0 ]; then
    echo "ERROR: no files matched '${path}'" >&2
    exit 1
  fi

  # Verify all matched files exist and are regular files.
  local f
  for f in "${matches[@]}"; do
    if [ ! -f "${f}" ]; then
      echo "ERROR: not a regular file: ${f}" >&2
      exit 1
    fi
  done

  printf '%s\n' "${matches[@]}"
}

# ---------------------------------------------------------------------------
# Safe ZIP extraction (defends against zip-slip / path traversal)
# ---------------------------------------------------------------------------
safe_unzip() {
  local zipfile="$1"
  local dest="$2"
  python3 - "$zipfile" "$dest" <<'PY'
import os, sys, zipfile
zip_path, dest = sys.argv[1], sys.argv[2]
dest_real = os.path.realpath(dest) + os.sep
with zipfile.ZipFile(zip_path, 'r') as zf:
    for member in zf.namelist():
        target = os.path.realpath(os.path.join(dest, member))
        if not target.startswith(dest_real):
            print(f"ERROR: zip-slip path detected: {member}", file=sys.stderr)
            sys.exit(1)
    zf.extractall(dest)
PY
}

# ---------------------------------------------------------------------------
# Common migration flow
# ---------------------------------------------------------------------------
prepare_migration() {
  require_env
  require_docker
  check_immich_running
  ensure_immich_go
}

run_migration() {
  local staging_dir="$1"
  shift
  local cmd=("$@")

  if prompt_yes_no "Run a dry-run first to preview what will be imported?" "y"; then
    echo ""
    echo "[migrate] === Dry-run (no uploads yet) ==="
    (
      export IMMICH_GO_UPLOAD_SERVER="${SERVER_URL}"
      export IMMICH_GO_UPLOAD_API_KEY="${IMMICH_API_KEY}"
      "${cmd[@]}" --dry-run || true
    )
    echo ""
    if ! prompt_yes_no "Proceed with the real import?" "n"; then
      echo "[migrate] Import cancelled."
      cleanup_staging "${staging_dir}"
      exit 0
    fi
  fi

  echo ""
  echo "[migrate] === Starting import ==="
  echo "[migrate] This may take hours for large libraries. It is resumable."
  (
    export IMMICH_GO_UPLOAD_SERVER="${SERVER_URL}"
    export IMMICH_GO_UPLOAD_API_KEY="${IMMICH_API_KEY}"
    "${cmd[@]}"
  )
}

cleanup_staging() {
  local staging_dir="$1"
  if prompt_yes_no "Remove temporary staging directory ${staging_dir}?" "y"; then
    rm -rf "${staging_dir}"
    echo "[migrate] Staging directory removed."
  else
    echo "[migrate] Staging directory kept at: ${staging_dir}"
  fi
}
