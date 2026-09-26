#!/usr/bin/env bash
# Publishes each service to the tailnet (HTTPS, tailnet-only) at
# https://<this machine's tailscale name>:<port>. Everything is bound to 127.0.0.1 on the
# box; tailscale serve is the only way in. Run on the box; safe to re-run.
set -euo pipefail
serve() { sudo tailscale serve --bg --https="$1" "http://127.0.0.1:$2" >/dev/null; printf '%-6s -> 127.0.0.1:%s  %s\n' ":$1" "$2" "$3"; }

serve 443  3090 "home page"
serve 3001 3001 "Witness agent-service"
serve 3300 3000 "Grafana"
serve 3400 3400 "Model Bench"
serve 3443 4180 "Witness studio (behind oauth2-proxy)"
serve 3501 3501 "Investment Studio agent-service (also the panels origin)"
serve 3543 3502 "Investment Studio"
serve 3600 3110 "Mongoku (read-only MongoDB browser)"
serve 8443 8085 "Witness Google OAuth callback"

# Path-based, on the tailnet name itself: https://server/llm/ reaches the local
# inference shim without anyone remembering a port. tailscale strips the prefix
# before forwarding, so the page it serves asks for its API relative to where it
# was loaded.
path() { sudo tailscale serve --bg --set-path="$1" "http://127.0.0.1:$2" >/dev/null; printf '%-6s -> 127.0.0.1:%s  %s\n' "$1" "$2" "$3"; }
path /llm 8091 "local inference shim (admin page at /llm/admin/)"
