#!/usr/bin/env bash
set -euo pipefail

# Set up Tailscale Funnel to expose Immich to the internet securely.
# Run this from the repository root: ./immich/setup-tailscale.sh
#
# This script will:
#   1. Verify Immich is installed and running.
#   2. Install Tailscale if it is missing.
#   3. Ensure immich/.env contains TAILSCALE_AUTHKEY (prompts if missing).
#   4. Authenticate this machine to your Tailnet.
#   5. Enable Tailscale Funnel for Immich on port 2283.
#
# After setup, Immich is available on the public internet at:
#   https://<machine-name>.<tailnet>.ts.net
#
# No router port forwarding, public IP, or domain name is required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./libs/lib.sh

require_docker
require_env
require_command curl

# --- 1. Make sure Immich is running locally ---
if ! curl -fsS "http://127.0.0.1:2283/api/server/ping" >/dev/null 2>&1; then
  echo "ERROR: Immich does not appear to be running at http://127.0.0.1:2283."
  echo "       Run ./immich/start.sh first, then try again."
  exit 1
fi

# --- 2. Ensure TAILSCALE_AUTHKEY is set ---
# Keep the Tailscale authkey in its own file so it is not loaded into the
# Immich application containers via docker-compose.yml env_file.
TAILSCALE_ENV_FILE="${IMMICH_DIR}/.env.tailscale"
TAILSCALE_AUTHKEY="$(env_value TAILSCALE_AUTHKEY "${TAILSCALE_ENV_FILE}")"

# If the key is still in the old immich/.env location (pre-0.0 migration),
# move it to .env.tailscale and remove it from .env automatically.
if [ -z "${TAILSCALE_AUTHKEY}" ] && [ -f "${IMMICH_DIR}/.env" ]; then
  TAILSCALE_AUTHKEY="$(env_value TAILSCALE_AUTHKEY)"
  if [ -n "${TAILSCALE_AUTHKEY}" ]; then
    echo "[setup] Migrating TAILSCALE_AUTHKEY from .env to .env.tailscale..."
    {
      echo "# Tailscale Funnel authkey. Generated at https://login.tailscale.com/admin/settings/keys"
      echo "TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY}"
    } > "${TAILSCALE_ENV_FILE}"
    chmod 600 "${TAILSCALE_ENV_FILE}"
    grep -v '^TAILSCALE_AUTHKEY=' "${IMMICH_DIR}/.env" > "${IMMICH_DIR}/.env.tmp"
    chmod 600 "${IMMICH_DIR}/.env.tmp"
    mv -f "${IMMICH_DIR}/.env.tmp" "${IMMICH_DIR}/.env"
  fi
fi

if [ -z "${TAILSCALE_AUTHKEY}" ]; then
  echo ""
  echo "Tailscale Funnel requires an authkey."
  echo "Generate one at: https://login.tailscale.com/admin/settings/keys"
  echo "Use an 'ephemeral' + 'reusable' + 'pre-authorized' key for servers."
  echo ""
  read -rsp "Paste your Tailscale authkey (input hidden): " TAILSCALE_AUTHKEY
  echo ""

  if [ -z "${TAILSCALE_AUTHKEY}" ]; then
    echo "ERROR: no authkey provided." >&2
    exit 1
  fi

  {
    echo "# Tailscale Funnel authkey. Generated at https://login.tailscale.com/admin/settings/keys"
    echo "TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY}"
  } > "${TAILSCALE_ENV_FILE}"
  chmod 600 "${TAILSCALE_ENV_FILE}"
  echo "[setup] Saved TAILSCALE_AUTHKEY to immich/.env.tailscale"
fi

# --- 3. Install Tailscale if missing ---
if ! command -v tailscale >/dev/null 2>&1; then
  echo "[setup] Tailscale is not installed. Installing..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "[setup] Tailscale is already installed."
fi

# --- 4. Start / verify tailscaled ---
if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
  echo "[setup] Starting tailscaled service..."
  sudo systemctl enable --now tailscaled
fi

# --- 5. Authenticate with the authkey ---
if ! tailscale status >/dev/null 2>&1; then
  echo "[setup] Authenticating with Tailscale..."
  # Pass the key via a temporary file using Tailscale's file: prefix so the
  # secret never appears in the process list.
  authkey_tmp="$(mktemp)"
  printf '%s' "${TAILSCALE_AUTHKEY}" > "${authkey_tmp}"
  chmod 600 "${authkey_tmp}"
  trap 'rm -f "${authkey_tmp}"' RETURN
  sudo tailscale up --auth-key="file:${authkey_tmp}" --accept-routes=false --ssh
else
  echo "[setup] Already authenticated to Tailscale."
fi

# --- 6. Enable Funnel ---
echo "[setup] Enabling Tailscale Funnel on this machine's Tailscale name..."
echo "[setup] This may take up to 60 seconds. Press Ctrl+C to cancel."

# Try to reset any stale funnel state, then enable with a timeout so we do not
# hang forever if Tailscale cannot provision the certificate.
reset_funnel() {
  echo "[setup] Resetting any existing Funnel state..."
  timeout 30 sudo tailscale funnel --yes --bg 127.0.0.1:2283 || true
}

enable_funnel() {
  echo "[setup] Running: sudo tailscale funnel --yes --bg 127.0.0.1:2283"
  timeout 90 sudo tailscale funnel --yes --bg 127.0.0.1:2283
}

reset_funnel
if ! enable_funnel; then
  echo "ERROR: Tailscale Funnel could not be enabled within 90 seconds." >&2
  echo "       Common causes:" >&2
  echo "         - This machine is not yet visible in the Tailscale admin console." >&2
  echo "         - The tailnet has not enabled Funnel for your account." >&2
  echo "         - Tailscale DNS / certificate provisioning is slow." >&2
  echo "       Check status with: sudo tailscale funnel status" >&2
  echo "       Retry later with:  ./immich/setup-tailscale.sh" >&2
  exit 1
fi

# --- 7. Report public URL ---
TAILSCALE_NAME="$(tailscale status --self --peers=false 2>/dev/null | awk 'NR==1{print $1}' || true)"
TAILNET_DNS="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("magicDNSSuffix",""))' || true)"
PUBLIC_URL="https://${TAILSCALE_NAME}${TAILNET_DNS}"

# Persist the setup-completed marker so immich/start.sh re-enables Funnel.
touch "${IMMICH_DIR}/.tailscale-funnel-setup-done"

echo ""
echo "[setup] Tailscale Funnel is active."
echo ""
echo "  Public URL:  ${PUBLIC_URL}"
echo "  Local URL:   http://127.0.0.1:2283"
echo ""
echo "  Check status: sudo tailscale funnel status"
echo ""
echo "First-time login: create the admin account at ${PUBLIC_URL}/auth/register"
