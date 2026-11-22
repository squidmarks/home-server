#!/usr/bin/env bash
# Copy the agent-studio working tree to the box and stamp it with the commit it came from,
# so every benchmark result can say which code produced it.
#   ./sync-agent-studio.sh [path-to-agent-studio] [host]     (defaults: ../agent-studio, server)
# Never copies env files, dependencies, build output, benchmark results or the cases (cases
# are edited on the box, in the UI, and are the authoritative copy there). Removes files
# deleted from the checkout, except what only the box has (sync-protect.txt).
set -euo pipefail
cd "$(dirname "$0")"
SRC="${1:-../agent-studio}"
HOST="${2:-server}"
version="$(git -C "$SRC" rev-parse --short HEAD)"
# "-dirty" when tracked files differ from that commit (untracked scratch files don't count)
[ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] && version="$version-dirty"
# --delete: files removed from the checkout are removed on the box too. A stale
# source file left behind (routes/embed.ts, 2026-11-22) broke the image build.
# What only the box has is protected (sync-protect.txt); excluded paths are kept.
rsync -a --delete --filter="merge sync-protect.txt" --exclude-from=sync-excludes.txt "$SRC"/ "$HOST":agent-studio/
# new cases from the repo are added, but cases already on the box are never overwritten
rsync -a --ignore-existing "$SRC"/scripts/bench/cases/ "$HOST":agent-studio/scripts/bench/cases/
echo "$version" | ssh "$HOST" 'cat > ~/agent-studio/.build-info'
echo "synced $SRC to $HOST:agent-studio as $version"
