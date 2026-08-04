# MemoriQ

A self-hosted family photo album. Your photos, videos, and metadata stay on your own hardware.

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/ahaqqu/MemoriQ.git
cd MemoriQ

# 2. Install Docker (Linux only) and start Immich
./immich/setup.sh

# 3. Create the first admin account
open http://127.0.0.1:2283/auth/register
```

That's it. MemoriQ runs at `http://127.0.0.1:2283`.

> **macOS / Windows:** install [Docker Desktop](https://www.docker.com/products/docker-desktop/) first, then run `./immich/setup.sh`.
>
> **Linux permission note:** if `setup.sh` says your user is not in the `docker` group, log out and back in (or run `newgrp docker`), then re-run `./immich/setup.sh`.

## Daily commands

| Task | Command |
|------|---------|
| Start | `./immich/start.sh` |
| Stop | `./immich/stop.sh` |
| Update to the pinned release | `./immich/update.sh` |
| Update to a new release | `./immich/set-version.sh <version>` |
| Backup to an external disk | `./immich/backup.sh <destination>` |
| Restore from a backup | `./immich/restore.sh <backup-folder>` |
| Migrate from Google Photos | `./immich/migrate-from-google-photos.sh` |
| Migrate from iCloud Photos | `./immich/migrate-from-icloud.sh` |

## First-time configuration

After creating the admin user:

1. **Add family members** — Administration → Users → Create user.
2. **Enable mobile backup** — install the Immich app and turn on Background backup.
3. **Review settings** — Administration → Settings:
   - Storage template (default: `yyyy/MM/yyyyMMdd`)
   - Trash retention (default: 30 days)
   - Machine learning (Smart Search / Facial Recognition)

## Optional: access from anywhere

### Secure public access with Tailscale Funnel

The setup script can expose Immich on a free HTTPS URL like `https://<machine>.<tailnet>.ts.net` with no port forwarding.

1. Generate an authkey at https://login.tailscale.com/admin/settings/keys. Recommended settings: **Reusable**, **Ephemeral**, **Pre-approved**.
2. Run `./immich/setup.sh` and answer `y` when it asks about Tailscale, or run `./immich/setup-tailscale.sh` later.

After setup, Immich is available at both the local URL and the public URL printed by the script. Check status anytime with `sudo tailscale funnel status`.

### LAN access

For LAN-only access, put a reverse proxy with TLS in front of `127.0.0.1:2283`. Do not expose the admin registration page to untrusted networks.

## Migrate from Google Photos

Import your existing Google Photos library from a Google Takeout ZIP archive.

1. Request a Google Takeout for **Google Photos** at https://takeout.google.com.
   - Choose **ZIP** and **50 GB** per archive.
   - Download all parts.
2. Move the ZIP file(s) to your MemoriQ server.
3. Run the migration script:

```bash
./immich/migrate-from-google-photos.sh
```

The script will:
- Extract the ZIP(s) automatically.
- Create an Immich API key from your admin account and cache it securely.
- Run a dry-run preview first, then import photos, videos, albums, dates, and GPS.
- Skip duplicates if re-run.

Keep your Takeout archives until you have verified the migration in Immich.

## Migrate from iCloud Photos

Import your existing iCloud Photos library from an Apple data export ZIP archive.

1. Request an iCloud data export for **iCloud Photos** at https://privacy.apple.com.
   - Download all parts.
2. Move the ZIP file(s) to your MemoriQ server.
3. Run the migration script:

```bash
./immich/migrate-from-icloud.sh
```

The script will:
- Extract the ZIP(s) automatically.
- Create an Immich API key from your admin account and cache it securely.
- Run a dry-run preview first, then import photos, videos, albums, and dates.
- Skip duplicates if re-run.

Keep your iCloud export archives until you have verified the migration in Immich.

## Backup and restore

All data lives under `./data/immich/` by default. The database password is only in `immich/.env` — keep that file safe.

```bash
# Backup: creates a timestamped folder immich-backup-YYYYMMDD-HHMMSS
./immich/backup.sh /mnt/external-disk/backups

# Restore: destructive; replaces current data with the backup
./immich/restore.sh /mnt/external-disk/backups/immich-backup-YYYYMMDD-HHMMSS
```

Use `./immich/restore.sh --yes <folder>` to skip confirmation.

---

**Maintainer notes** — how this repo is organized, the "scripted setup" rule, and service details are in [`AGENTS.md`](AGENTS.md).
