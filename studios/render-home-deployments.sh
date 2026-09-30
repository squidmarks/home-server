#!/usr/bin/env bash
# Render the studio deployment templates (studios/home-deployments) into
# $ENV_DIR/home-deployments, filling in {fqdn} from TAILNET_FQDN. Re-runnable;
# restart the agent-service afterwards to pick up changes.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
[ -n "$TAILNET_FQDN" ] || { echo "TAILNET_FQDN is not set (see env.sh); refusing to write studio URLs without it." >&2; exit 1; }
SRC="$(dirname "$0")/home-deployments"
DEST="$ENV_DIR/home-deployments"
mkdir -p "$DEST"
for t in "$SRC"/*/deployment.json; do
  name=$(basename "$(dirname "$t")")
  mkdir -p "$DEST/$name"
  sed "s|{fqdn}|$TAILNET_FQDN|g" "$t" > "$DEST/$name/deployment.json"
  echo "rendered $DEST/$name/deployment.json"
done
