#!/usr/bin/env bash
# The Mongo user for the access service: readWrite on db "access". Safe to
# re-run. Password from access/.env (ACCESS_DB_PASSWORD), never printed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
MONGO_ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
PW=$(grep '^ACCESS_DB_PASSWORD=' "$HERE/.env" | cut -d= -f2-)
[ -n "$PW" ] || { echo "ACCESS_DB_PASSWORD missing in access/.env" >&2; exit 1; }
docker exec -e PW="$PW" "$MONGO_CONTAINER" mongosh --quiet \
  "mongodb://root:${MONGO_ROOT_PW}@localhost:27017/admin?authSource=admin" --eval '
const d = db.getSiblingDB("access");
const roles = [{role: "readWrite", db: "access"}];
if (d.getUser("access")) { d.updateUser("access", {pwd: process.env.PW, roles}); print("updated access.access"); }
else { d.createUser({user: "access", pwd: process.env.PW, roles}); print("created access.access"); }
'
