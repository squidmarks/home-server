#!/usr/bin/env bash
# Copy this repo to the box's ~/infra and apply what changed.
#   ./deploy.sh [host]            (default host: gpu, an ssh alias)
# Never copies secrets or data: *.env files and mongo/data* are excluded and untouched.
set -euo pipefail
cd "$(dirname "$0")"
HOST="${1:-gpu}"
rsync -a --exclude '.git/' --exclude '*.env' --exclude '.env' --exclude 'node_modules/' \
  --exclude 'mongo/data*/' ./ "$HOST":infra/
ssh "$HOST" 'chmod +x ~/infra/bench/*.sh ~/infra/studios/*.sh ~/infra/mongo/*.sh ~/infra/tailscale/*.sh
  sudo cp ~/infra/bench/bench-worker.service /etc/systemd/system/bench-worker.service
  sudo systemctl daemon-reload && sudo systemctl restart bench-worker'
echo "deployed to $HOST:infra. Compose stacks are not restarted; recreate one with, e.g.:"
echo "  ssh $HOST 'cd ~/infra/home && docker compose up -d'"
