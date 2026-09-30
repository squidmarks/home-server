#!/usr/bin/env bash
# Setup on home: secrets (.env), read-only Mongo users (for the exporters and
# Mongoku), and the inference box's scrape targets. Safe to re-run. Then:
#   docker compose -f docker-compose.monitoring.yml up -d --build
# INFERENCE_FQDN (the GPU box's tailnet name) comes from the environment or
# .env; it is private, so it lives there rather than in this public repo.
set -euo pipefail
cd "$(dirname "$0")"
MONGO_ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' ~/infra/mongo/.env | cut -d= -f2)

if [ ! -f .env ]; then
  {
    echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 12)"
    echo "MONGO_MONITOR_PASSWORD=$(openssl rand -hex 16)"
    echo "STUDIO_METRICS_PASSWORD=$(openssl rand -hex 16)"
  } > .env
  chmod 600 .env
  echo "wrote .env"
fi
set -a; . ./.env; set +a

# Mongoku's read-only user; its password lives beside its compose file.
VIEWER_ENV=../mongoku/.env
if [ ! -f "$VIEWER_ENV" ]; then
  echo "VIEWER_PASSWORD=$(openssl rand -hex 16)" > "$VIEWER_ENV"
  chmod 600 "$VIEWER_ENV"
  echo "wrote $VIEWER_ENV"
fi
VIEWER_PASSWORD=$(grep '^VIEWER_PASSWORD=' "$VIEWER_ENV" | cut -d= -f2)

# The inference box's exporters, published on its tailnet name by tailscale/serve.sh.
if [ -n "${INFERENCE_FQDN:-}" ]; then
  mkdir -p prometheus/targets
  for e in node:9100 cadvisor:9180; do
    printf '[{"targets": ["%s:%s"], "labels": {"host": "inference"}}]\n' "$INFERENCE_FQDN" "${e#*:}" > "prometheus/targets/inference-${e%%:*}.json"
  done
  echo "wrote prometheus/targets for $INFERENCE_FQDN"
else
  echo "INFERENCE_FQDN is not set: the inference box will not be scraped" >&2
fi

docker exec mongo-mongo-1 mongosh --quiet "mongodb://root:${MONGO_ROOT_PW}@localhost:27017/admin?authSource=admin" --eval "
const admin = db.getSiblingDB('admin');
function upsert(user, pwd, roles) {
  try { admin.createUser({user, pwd, roles}); print('created ' + user); }
  catch (e) { admin.updateUser(user, {pwd, roles}); print('updated ' + user); }
}
// mongodb_exporter: server-wide stats only, no data access.
upsert('monitor', '${MONGO_MONITOR_PASSWORD}', [
  {role: 'clusterMonitor', db: 'admin'}, {role: 'read', db: 'local'}]);
// studio-exporter: read-only on the studios' platform database and Witness's own.
upsert('metrics', '${STUDIO_METRICS_PASSWORD}', [{role: 'read', db: 'agent_studio'}, {role: 'read', db: 'witness'}]);
// Mongoku: looks at everything, changes nothing.
upsert('viewer', '${VIEWER_PASSWORD}', [{role: 'readAnyDatabase', db: 'admin'}]);
"
echo "Grafana admin password is in $(pwd)/.env (GRAFANA_ADMIN_PASSWORD)"
