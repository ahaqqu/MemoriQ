# MemoriQ

A self-hosted family photo album. All photos, videos, and metadata stay on your own hardware.

## What you need

- A Linux, macOS, or Windows host running a Bash-compatible shell.
- Internet access to download Docker images.
- **Linux:** `setup.sh` installs Docker Engine and the Docker Compose plugin
  automatically. You need root or `sudo` access for the install step.
- **macOS / Windows:** install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
  first, then run `setup.sh`.

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/ahaqqu/MemoriQ.git
cd MemoriQ

# 2. Install Docker (if needed) and start Immich
./immich/setup.sh

# 3. Create the first admin account
# Open http://127.0.0.1:2283/auth/register and register the admin user.
```

> **Note:** If Docker was just installed and `setup.sh` prints a message about
> permissions, log out and back in (or run `newgrp docker`) so your user is
> added to the `docker` group, then re-run `./immich/setup.sh`.

## What `setup.sh` does

1. Installs Docker Engine and the Docker Compose plugin if they are missing
   (using the official `get.docker.com` installer).
2. Creates `immich/.env` from `immich/.env.example` with:
   - A randomly generated database password.
   - Your system timezone (falls back to `UTC`).
3. Creates the photo and database directories under `./data/immich/` with
   secure permissions.
4. Pulls the pinned Immich release images.
5. Starts the services and waits for them to become healthy.

`setup.sh` is idempotent: re-running it after the first run only re-applies
permission and directory checks; it will not upgrade or restart services.

## Daily commands

| Task | Script |
|------|--------|
| Start services | `./immich/start.sh` |
| Stop services | `./immich/stop.sh` |
| Re-apply the pinned release | `./immich/update.sh` |
| Change to a new pinned release | `./immich/set-version.sh <version>` |

## Updating Immich

Immich is pinned to a concrete release in `immich/.env` for reproducibility. To
move to a newer version, run the version helper with the target release tag:

```bash
# Read the release notes first: https://github.com/immich-app/immich/releases
./immich/set-version.sh v1.131.3
```

This updates the pinned version in `immich/.env` and runs `./immich/update.sh`
for you. No manual editing of `.env` is required.

## Data storage

Uploaded media and the database are stored under `./data/immich/` by default.
This path is configured in `immich/.env` and is git-ignored so large files are
never committed.

Keep regular backups of `./data/immich/` and `immich/.env`; the database
password is stored only in `.env`.

## Network and security

By default the web UI listens on `127.0.0.1:2283` only. This is the safest
choice for a single-machine setup. To expose MemoriQ to your LAN, place a
reverse proxy with TLS in front of it and do not leave the admin registration
page open to untrusted networks.

## What to configure after creating the admin user

Immich works out of the box, but for a family photo album you will usually want
at least one extra step:

### 1. Create accounts for family members

Only the admin account is created automatically. Add users from:
**Administration → Users → Create user**. Immich sends invites via email if
you configure SMTP; otherwise just give family members their username/password
or turn on OAuth.

### 2. Turn on automatic mobile backup (recommended)

Install the Immich mobile app and enable **Settings → Background backup**.
Photos and videos then upload to MemoriQ automatically when on Wi-Fi.

### 3. Review default settings

Open **Administration → Settings** and check the following at least once:

- **Storage template** — decide how uploaded files are organized on disk
  (default: `yyyy/MM/yyyyMMdd`).
- **Trash** — deleted items stay for 30 days by default; adjust if you want.
- **Machine learning** — Smart Search and Facial Recognition run automatically.
  Disable them if the server is low on CPU/RAM, or if you do not want facial
  recognition.
- **Image settings** — thumbnail quality/resolution affect storage use.

These are Immich features, not scripts, so they are configured through the web
UI. Defaults are safe for home use.

## Repository rules

See [`AGENTS.md`](AGENTS.md).

> **No manual setup.** Every host-level action goes through a committed script.
