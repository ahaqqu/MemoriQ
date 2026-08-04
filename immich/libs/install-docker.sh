#!/usr/bin/env bash
set -euo pipefail

# Install Docker Engine and the Docker Compose plugin using Docker's official
# convenience script. Supports most Linux distributions. May require sudo/root.
#
# This script is called automatically by setup.sh when Docker is missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "[install-docker] Docker and Docker Compose plugin are already installed."
  exit 0
fi

echo "[install-docker] Docker or the Docker Compose plugin is missing."

# The official get.docker.com script supports most Linux distributions. Other
# platforms require Docker Desktop, which must be installed by the user.
case "$(uname -s)" in
  Linux)
    echo "[install-docker] Installing Docker using the official get.docker.com script..."
    ;;
  Darwin)
    echo "ERROR: automatic Docker installation is not supported on macOS." >&2
    echo "Please install Docker Desktop for Mac (https://docs.docker.com/desktop/install/mac-install/), then re-run ./immich/setup.sh." >&2
    exit 1
    ;;
  CYGWIN*|MINGW*|MSYS*)
    echo "ERROR: automatic Docker installation is not supported on Windows." >&2
    echo "Please install Docker Desktop for Windows (https://docs.docker.com/desktop/install/windows-install/), then re-run ./immich/setup.sh." >&2
    exit 1
    ;;
  *)
    echo "ERROR: unsupported operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  echo "ERROR: root or sudo is required to install Docker on Linux." >&2
  exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

install_script() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://get.docker.com
  else
    echo "ERROR: curl or wget is required to download the Docker installer." >&2
    exit 1
  fi
}

# shellcheck disable=SC2091
$SUDO sh -c "$(install_script)"

# Try to add the current user to the docker group so they can run Docker without
# sudo. The group change normally requires a new login session.
DOCKER_USER="${SUDO_USER:-${USER}}"
if [ "$(id -u)" -ne 0 ] && command -v usermod >/dev/null 2>&1; then
  $SUDO usermod -aG docker "${DOCKER_USER}" 2>/dev/null || true
fi

echo "[install-docker] Docker installation complete."

if [ -n "${DOCKER_USER:-}" ]; then
  echo "[install-docker] Added ${DOCKER_USER} to the 'docker' group."
fi

if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  echo "[install-docker] The 'docker' group change requires a new login session." >&2
  echo "[install-docker] Please log out and back in (or run 'newgrp docker'), then re-run ./immich/setup.sh." >&2
  exit 1
fi

echo "[install-docker] If 'docker compose' is still not available, log out and back in (or run 'newgrp docker') and re-run ./immich/setup.sh."
