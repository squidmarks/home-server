#!/usr/bin/env bash
# Copy this repo to the box's ~/infra and apply what changed.
#   ./deploy.sh [host]            (default host: gpu, an ssh alias)
# Never copies secrets or data: *.env files and mongo/data* are excluded and untouched.
set -euo pipefail
cd "$(dirname "$0")"
HOST="${1:-gpu}"
rsync -a --exclude '.git/' --exclude '*.env' --exclude '.env' --exclude 'node_modules/' \
  --exclude 'mongo/data*/' ./ "$HOST":infra/
# Restarting the worker mid-job would abandon the run in flight, so wait for it.
ssh "$HOST" 'if pgrep -f "[b]ench-dev.sh run|[b]ench.sh run" >/dev/null; then
    echo "a benchmark job is running: deploying the files but NOT restarting the worker." >&2
    echo "restart it yourself when the queue is empty: sudo systemctl restart bench-worker" >&2
    exit 3
  fi' || { [ $? -eq 3 ] && SKIP_WORKER=1; }

ssh "$HOST" 'chmod +x ~/infra/bench/*.sh ~/infra/studios/*.sh ~/infra/mongo/*.sh ~/infra/tailscale/*.sh ~/infra/llama/*.sh
  sudo cp ~/infra/bench/bench-worker.service /etc/systemd/system/bench-worker.service
  sudo systemctl daemon-reload'
[ -n "${SKIP_WORKER:-}" ] || ssh "$HOST" 'sudo systemctl restart bench-worker'
echo "deployed to $HOST:infra. Compose stacks are not restarted; recreate one with, e.g.:"
echo "  ssh $HOST 'cd ~/infra/home && docker compose up -d'"
