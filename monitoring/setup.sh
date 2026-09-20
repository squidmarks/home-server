#!/usr/bin/env bash
# One-time setup on the server: secrets (.env) and read-only Mongo users.
# Safe to re-run. Then: docker compose -f docker-compose.monitoring.yml up -d --build
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

docker exec mongo-mongo-1 mongosh --quiet "mongodb://root:${MONGO_ROOT_PW}@localhost:27017/admin?authSource=admin" --eval "
const admin = db.getSiblingDB('admin');
function upsert(user, pwd, roles) {
  try { admin.createUser({user, pwd, roles}); print('created ' + user); }
  catch (e) { admin.updateUser(user, {pwd, roles}); print('updated ' + user); }
}
// mongodb_exporter: server-wide stats only, no data access.
upsert('monitor', '${MONGO_MONITOR_PASSWORD}', [
  {role: 'clusterMonitor', db: 'admin'}, {role: 'read', db: 'local'}]);
// studio-exporter: read-only on the production Witness database.
upsert('metrics', '${STUDIO_METRICS_PASSWORD}', [{role: 'read', db: 'witness_deployed'}]);
"
echo "Grafana admin password is in $(pwd)/.env (GRAFANA_ADMIN_PASSWORD)"
