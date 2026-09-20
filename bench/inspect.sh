#!/usr/bin/env bash
# Look at a benchmark run inside the Investment Studio's own UI.
#   inspect.sh load <run> <model> <case>   save the workbench, load the run's database into it
#   inspect.sh unload                      put the workbench back as it was
#   inspect.sh status
#
# The run used the same dev user and customer as the workbench, so once loaded its agents,
# sessions and panels show up in the normal studio pages. Loaded SCHEDULES ARE DELETED so a
# restored "run daily" agent can never start trading the paper account. While a run is
# loaded, whatever you do in the workbench is discarded when you unload.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
STATE="${INSPECT_STATE:-$HOME/infra/bench-ui-data/inspect-state.json}"
BACKUPS="${BACKUPS_DIR:-$HOME/backups}"
ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
URI="mongodb://root:${ROOT_PW}@localhost:27017/?authSource=admin"
DB=benchmark_studio
mongosh_root() { docker exec "$MONGO_CONTAINER" mongosh --quiet "$URI" "$@"; }

case "${1:-}" in
  load)
    [ $# -eq 4 ] || { sed -n '2,6p' "$0"; exit 2; }
    run="$2"; model="$3"; case_id="$4"
    archive="$BENCH_DIR/results/$run/$model/$case_id.mongo.gz"
    [ -s "$archive" ] || { echo "no archive at $archive (only runs made after archiving was added have one)" >&2; exit 1; }
    [ -f "$STATE" ] && { echo "a run is already loaded; run 'inspect.sh unload' first" >&2; exit 1; }
    mkdir -p "$BACKUPS"
    saved="$BACKUPS/workbench-before-inspect-$(date +%Y%m%d-%H%M%S).archive.gz"
    docker exec "$MONGO_CONTAINER" mongodump --uri="$URI" --db="$DB" --archive --gzip 2>/dev/null > "$saved"
    [ -s "$saved" ] || { echo "could not save the workbench first; nothing changed" >&2; rm -f "$saved"; exit 1; }
    printf '{"saved":"%s","run":"%s","model":"%s","case":"%s","at":"%s"}\n' "$saved" "$run" "$model" "$case_id" "$(date -u +%FT%TZ)" > "$STATE"
    mongosh_root --eval "db.getSiblingDB('$DB').dropDatabase()" >/dev/null
    docker exec -i "$MONGO_CONTAINER" mongorestore --uri="$URI" --archive --gzip --nsFrom='benchmark_run.*' --nsTo="$DB.*" < "$archive" >/dev/null 2>&1
    mongosh_root --eval "db.getSiblingDB('$DB').scheduled_jobs.deleteMany({})" >/dev/null
    echo "loaded $run / $model / $case_id into the Investment Studio (schedules removed)."
    echo "workbench saved to $saved; run 'inspect.sh unload' when done."
    ;;
  unload)
    [ -f "$STATE" ] || { echo "nothing is loaded" >&2; exit 1; }
    saved=$(python3 -c "import json,sys;print(json.load(open('$STATE'))['saved'])")
    [ -s "$saved" ] || { echo "the saved workbench $saved is missing; not touching anything" >&2; exit 1; }
    mongosh_root --eval "db.getSiblingDB('$DB').dropDatabase()" >/dev/null
    docker exec -i "$MONGO_CONTAINER" mongorestore --uri="$URI" --archive --gzip --nsInclude="$DB.*" < "$saved" >/dev/null 2>&1
    rm -f "$STATE"
    echo "workbench restored from $saved."
    ;;
  status)
    [ -f "$STATE" ] && { echo "loaded: $(cat "$STATE")"; } || echo "nothing loaded; the workbench is as you left it"
    ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
