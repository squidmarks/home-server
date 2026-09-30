#!/usr/bin/env bash
# Publishes this machine's services to the tailnet (HTTPS, tailnet-only) at
# https://<this machine's tailscale name>:<port>. Everything is bound to 127.0.0.1 on the
# box; tailscale serve is the only way in. Run on the box; safe to re-run.
# One list per box: `home` runs the studios and the home page, `server` (the
# inference box) runs inference and, until they move, the bench and monitoring.
set -euo pipefail
serve() { sudo tailscale serve --bg --https="$1" "http://127.0.0.1:$2" >/dev/null; printf '%-6s -> 127.0.0.1:%s  %s\n' ":$1" "$2" "$3"; }

# Path-based, on the tailnet name itself: https://server/llm/ reaches the local
# inference shim without anyone remembering a port. tailscale strips the prefix
# before forwarding, so the page it serves asks for its API relative to where it
# was loaded.
path() { sudo tailscale serve --bg --set-path="$1" "http://127.0.0.1:$2" >/dev/null; printf '%-6s -> 127.0.0.1:%s  %s\n' "$1" "$2" "$3"; }

case "$(hostname)" in
  home)
    # :443 belongs to Caddy (caddy/), which serves every name under the domain.
    serve 3001 3001 "shared agent-service, all studios (also the panels origin)"
    serve 3743 3702 "Home Studio"
    serve 3443 4180 "Witness studio (behind oauth2-proxy)"
    serve 8443 8085 "Witness Google OAuth callback"
    serve 3543 3704 "Investment Studio"
    # Home Assistant's webhook port is NOT served here: tailscale serve routes by
    # hostname and HA can only call the IP. studios/home.yml publishes it
    # directly on the tailnet IP instead.
    ;;
  server)
    # The studios moved to home; the bench and monitoring stay here until they do.
    serve 3300 3000 "Grafana"
    serve 3400 3400 "Model Bench"
    serve 3600 3110 "Mongoku (read-only MongoDB browser)"
    path /llm 8091 "local inference shim (admin page at /llm/admin/)"
    ;;
  *) echo "no tailscale serve mapping for host $(hostname)" >&2; exit 1 ;;
esac
