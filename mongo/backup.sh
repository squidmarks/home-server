#!/usr/bin/env bash
# Daily logical backup of this box's databases (one gzip archive per database),
# keeping the newest 14 of each. Which databases: BACKUP_DBS in mongo/.env
# (space-separated; default agent_studio; home also keeps witness and the bench
# baseline witness_bench_base). Restore one with:
#   docker exec -i mongo-mongo-1 mongorestore --archive --gzip --uri=... < file
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(grep "^MONGO_ROOT_PASSWORD=" .env | cut -d= -f2)
DBS=$(grep "^BACKUP_DBS=" .env | cut -d= -f2- || true)
DEST="$HOME/backups/mongo"; STAMP=$(date +%Y%m%d-%H%M)
mkdir -p "$DEST"
URI="mongodb://root:$ROOT@localhost:27017/?authSource=admin"
for DB in ${DBS:-agent_studio}; do
  OUT="$DEST/$DB-$STAMP.archive.gz"
  docker exec mongo-mongo-1 mongodump --uri="$URI" --db="$DB" --archive --gzip --quiet > "$OUT.tmp"
  # A backup that cannot be read back is not a backup: list it before keeping it.
  docker exec -i mongo-mongo-1 mongorestore --uri="$URI" \
    --archive --gzip --dryRun --nsInclude="$DB.*" < "$OUT.tmp" >/dev/null 2>&1
  mv "$OUT.tmp" "$OUT"
  ls -1t "$DEST/$DB"-*.archive.gz | tail -n +15 | xargs -r rm -f
  echo "backup ok: $OUT ($(du -h "$OUT" | cut -f1))"
done
