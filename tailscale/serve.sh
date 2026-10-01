#!/usr/bin/env bash
# Publishes this machine's services to the tailnet (HTTPS, tailnet-only) at
# https://<this machine's tailscale name>:<port>. Everything is bound to 127.0.0.1 on the
# box; tailscale serve is the only way in. Run on the box; safe to re-run.
# One list per box: `home` runs the studios and the home page, `server` (the
# inference box) runs inference and the exporters home scrapes.
set -euo pipefail
serve() { sudo tailscale serve --bg --https="$1" "http://127.0.0.1:$2" >/dev/null; printf '%-6s -> 127.0.0.1:%s  %s\n' ":$1" "$2" "$3"; }

# Path-based, on the tailnet name itself: https://server/llm/ reaches the local
# inference shim without anyone remembering a port. tailscale strips the prefix
# before forwarding, so the page it serves asks for its API relative to where it
# was loaded.
path() { sudo tailscale serve --bg --set-path="$1" "http://127.0.0.1:$2" >/dev/null; printf '%-6s -> 127.0.0.1:%s  %s\n' "$1" "$2" "$3"; }

case "$(hostname)" in
  home)
    # Nothing: Caddy (caddy/) serves every name under the domain on this box's
    # tailnet IP, so no service here needs a tailscale serve port.
    ;;
  server)
    # Studios, monitoring, Mongoku and the bench all run on home now.
    serve 9100 9100 "node exporter (scraped by Prometheus on home)"
    serve 9180 9180 "cAdvisor (scraped by Prometheus on home)"
    path /llm 8091 "local inference shim (admin page at /llm/admin/)"
    ;;
  *) echo "no tailscale serve mapping for host $(hostname)" >&2; exit 1 ;;
esac
