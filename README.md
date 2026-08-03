# MemoriQ

A self-hosted family photo album. All photos, videos, and metadata stay on your own hardware.

## Quick Start

```bash
# 1. Clone this repo
git clone <repo-url> MemoriQ
cd MemoriQ

# 2. Install and start Immich (photo/video server)
./immich/setup.sh

# 3. Open the web app
# http://localhost:2283
```

## Daily Commands

| Task | Script |
|------|--------|
| Start services | `./immich/start.sh` |
| Stop services | `./immich/stop.sh` |
| Update to latest release | `./immich/update.sh` |

## Repository Rules

See [`AGENTS.md`](AGENTS.md).

> **No manual setup.** Every host-level action goes through a committed script.

## Data Storage

Uploaded media and the database are stored under `./data/immich/` by default. This path is configured in `immich/.env` and is git-ignored so large files are never committed.
