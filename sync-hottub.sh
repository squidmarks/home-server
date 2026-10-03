#!/usr/bin/env bash
# Copy the hot tub web app (hottub-firmware repo, webapp/) to the box, then
# rebuild and restart it.
#   ./sync-hottub.sh [path-to-hottub-firmware] [host]   (defaults: ../hottub-firmware, home)
set -euo pipefail
cd "$(dirname "$0")"
SRC="${1:-../hottub-firmware}"
HOST="${2:-home}"
ssh "$HOST" "mkdir -p ~/hottub/webapp"
rsync -a --delete --exclude '__pycache__/' --exclude '.venv/' --exclude '.env' \
  "$SRC"/webapp/ "$HOST":hottub/webapp/
ssh "$HOST" 'cd ~/infra/hottub && docker compose up -d --build'
echo "synced $SRC/webapp to $HOST:hottub/webapp ($(git -C "$SRC" rev-parse --short HEAD)) and restarted"
