#!/usr/bin/env bash
# Render the studio deployment templates (studios/home-deployments) into
# $ENV_DIR/home-deployments, filling in {domain} from STUDIOS_DOMAIN (the
# environment, else studios.env). Re-runnable; restart the agent-service
# afterwards to pick up changes.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
DOMAIN="${STUDIOS_DOMAIN:-$(grep -m1 '^STUDIOS_DOMAIN=' "$ENV_DIR/studios.env" 2>/dev/null | cut -d= -f2-)}"
[ -n "$DOMAIN" ] || { echo "STUDIOS_DOMAIN is not set (environment or studios.env); refusing to write studio URLs without it." >&2; exit 1; }
SRC="$(dirname "$0")/home-deployments"
DEST="$ENV_DIR/home-deployments"
mkdir -p "$DEST"
for t in "$SRC"/*/deployment.json; do
  name=$(basename "$(dirname "$t")")
  mkdir -p "$DEST/$name"
  sed "s|{domain}|$DOMAIN|g" "$t" > "$DEST/$name/deployment.json"
  echo "rendered $DEST/$name/deployment.json"
done
