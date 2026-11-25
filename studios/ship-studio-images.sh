#!/usr/bin/env bash
# Build the studios that live in their own repositories (Witness, Home; agent-studio
# ADR-0123) on this machine and load their images on the box over ssh. No registry:
# the images go straight from `docker save` to the box's `docker load`.
#   ./studios/ship-studio-images.sh [studio...]      (default: witness home)
# Expects checkouts beside this repo: ../agent-studio (the platform, for the base
# images) and ../studio-<name>. HOST (default: home), AGENT_STUDIO_DIR and
# STUDIOS_DIR override those. Loads the images only; recreate the containers
# afterwards (the last line says how).
#
# The web images bake in the studios' public URLs. Those two settings
# (STUDIOS_DOMAIN, MCP_PUBLIC_URL) are read from the box's studios.env, one key
# at a time, and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${HOST:-home}"
PLATFORM="${AGENT_STUDIO_DIR:-../agent-studio}"
STUDIOS="${STUDIOS_DIR:-..}"
[ $# -gt 0 ] || set -- witness home

setting() {
  ssh "$HOST" "grep -E '^$1=' ~/agent-studio/studios.env | tail -1 | cut -d= -f2-" \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
version() {
  local v; v="$(git -C "$1" rev-parse --short HEAD)"
  [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ] || v="$v-dirty"
  echo "$v"
}

DOMAIN="$(setting STUDIOS_DOMAIN)"
MCP_URL="$(setting MCP_PUBLIC_URL)"
[ -n "$DOMAIN" ] || { echo "STUDIOS_DOMAIN is not set in $HOST:~/agent-studio/studios.env" >&2; exit 1; }

# The platform's base images, at the platform checkout's commit.
pv="$(version "$PLATFORM")"
echo "▸ platform base images at $pv"
docker build -q -f "$PLATFORM/packages/engine-runner/Dockerfile" --target runtime -t "agent-studio-runner-base:$pv" "$PLATFORM" >/dev/null
docker build -q -f "$PLATFORM/packages/engine-runner/Dockerfile" --target build -t "agent-studio-runner-base:$pv-build" "$PLATFORM" >/dev/null
docker build -q -f "$PLATFORM/apps/studio-web/Dockerfile" --target web-builder -t "agent-studio-web-builder:$pv" "$PLATFORM" >/dev/null

for s in "$@"; do
  dir="$STUDIOS/studio-$s"
  [ -f "$dir/runner.Dockerfile" ] || { echo "no studio repository at $dir" >&2; exit 1; }
  v="$(version "$dir")"
  echo "▸ $s at $v"
  docker build -q -f "$dir/runner.Dockerfile" --build-arg "RUNNER_BASE=agent-studio-runner-base:$pv" \
    -t "studio-$s-runner:$v" -t "studio-$s-runner:latest" "$dir" >/dev/null
  docker build -q -f "$dir/web.Dockerfile" --build-arg "WEB_BUILDER=agent-studio-web-builder:$pv" \
    --build-arg "NEXT_PUBLIC_AGENT_SERVICE_URL=https://api.$DOMAIN" \
    --build-arg "NEXT_PUBLIC_AUTH_ENABLED=false" \
    --build-arg "NEXT_PUBLIC_MCP_PUBLIC_URL=$MCP_URL" \
    --build-arg "NEXT_PUBLIC_BUILD_VERSION=$v+platform-$pv" \
    -t "studio-$s-web:$v" -t "studio-$s-web:latest" "$dir" >/dev/null
  docker save "studio-$s-runner:$v" "studio-$s-runner:latest" "studio-$s-web:$v" "studio-$s-web:latest" \
    | gzip -1 | ssh "$HOST" 'gunzip | docker load' | sed 's/^/  /'
done

echo "loaded on $HOST. Recreate the containers with:"
echo "  ssh $HOST 'cd ~/agent-studio && docker compose -f ~/infra/studios/home.yml --env-file studios.env up -d home-runner witness-runner home-studio-web witness-web'"
