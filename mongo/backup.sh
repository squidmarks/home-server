#!/usr/bin/env bash
# Daily logical backup of the production Witness database (gzip archive), keeping the
# newest 14. Restore with:  docker exec -i mongo-mongo-1 mongorestore --archive --gzip --uri=... < file
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(grep "^MONGO_ROOT_PASSWORD=" .env | cut -d= -f2)
DEST="$HOME/backups/mongo"; STAMP=$(date +%Y%m%d-%H%M)
OUT="$DEST/witness_deployed-$STAMP.archive.gz"
docker exec mongo-mongo-1 mongodump --uri="mongodb://root:$ROOT@localhost:27017/?authSource=admin" \
  --db=witness_deployed --archive --gzip --quiet > "$OUT.tmp"
# A backup that cannot be read back is not a backup: list it before keeping it.
docker exec -i mongo-mongo-1 mongorestore --uri="mongodb://root:$ROOT@localhost:27017/?authSource=admin" \
  --archive --gzip --dryRun --nsInclude="witness_deployed.*" < "$OUT.tmp" >/dev/null 2>&1
mv "$OUT.tmp" "$OUT"
ls -1t "$DEST"/witness_deployed-*.archive.gz | tail -n +15 | xargs -r rm -f
echo "backup ok: $OUT ($(du -h "$OUT" | cut -f1))"
