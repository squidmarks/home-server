#!/usr/bin/env bash
# Put the path routing in place. Re-runnable.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
sudo mkdir -p /etc/nginx/snippets
sudo cp "$HERE/server-proxy.conf" /etc/nginx/snippets/server-proxy.conf
sudo cp "$HERE/server.conf" /etc/nginx/sites-available/server.conf
sudo ln -sf /etc/nginx/sites-available/server.conf /etc/nginx/sites-enabled/server.conf
# The stock default server also claims port 80 and would shadow this one.
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
echo "routing live:  http://server/ (-> /llm/admin/)  /llm/  /bench/  /grafana/  /mongo/"
