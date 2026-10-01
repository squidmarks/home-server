#!/usr/bin/env bash
# The bench's database users, on the Mongo of the box the bench runs on. Safe to
# re-run. Passwords come from the bench env files (never printed):
#   bench          readWrite on witness_bench     (BENCH_DB_PASSWORD, bench.env)
#   benchmark_run  readWrite on benchmark_run     (BENCHMARK_RUN_DB_PASSWORD, benchmark-run.env)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
MONGO_ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
val() { grep "^$2=" "$ENV_DIR/$1" | head -1 | cut -d= -f2-; }
BENCH_PW=$(val bench.env BENCH_DB_PASSWORD)
RUN_PW=$(val benchmark-run.env BENCHMARK_RUN_DB_PASSWORD)
[ -n "$BENCH_PW" ] && [ -n "$RUN_PW" ] || { echo "missing a password in bench.env / benchmark-run.env" >&2; exit 1; }
# Passed through the environment, not the command line, so they stay out of ps.
docker exec -e BENCH_PW="$BENCH_PW" -e RUN_PW="$RUN_PW" "$MONGO_CONTAINER" mongosh --quiet \
  "mongodb://root:${MONGO_ROOT_PW}@localhost:27017/admin?authSource=admin" --eval '
function upsert(dbName, user, pwd, roles) {
  const d = db.getSiblingDB(dbName);
  if (d.getUser(user)) { d.updateUser(user, {pwd, roles}); print("updated " + dbName + "." + user); }
  else { d.createUser({user, pwd, roles}); print("created " + dbName + "." + user); }
}
upsert("witness_bench", "bench", process.env.BENCH_PW, [{role: "readWrite", db: "witness_bench"}]);
upsert("admin", "benchmark_run", process.env.RUN_PW, [{role: "readWrite", db: "benchmark_run"}]);
'
