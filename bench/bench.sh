#!/usr/bin/env bash
# Model benchmark orchestration. Run on the box that hosts Mongo + Docker.
#
#   ./bench.sh setup                      one-time: bench.env + pristine DB snapshot
#   ./bench.sh reset                      restore witness_bench from the snapshot
#   ./bench.sh run <model> [case ...]     reset, start bench agent-service on <model>,
#                                         run the cases, stop it
#
# <model> is any model id the agent-service knows (e.g. claude-sonnet-5,
# local-qwen3-32b). Results land in results/<runId>/<model>/<case>.json.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
cd "$BENCH_DIR"
ENV_FILE=$ENV_DIR/bench.env
PROD_ENV=$ENV_DIR/docker-compose.nuc.env
MONGO_ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
MONGO_URI_ROOT="mongodb://root:${MONGO_ROOT_PW}@localhost:27017/?authSource=admin"

mongosh_root() { docker exec "$MONGO_CONTAINER" mongosh --quiet "$MONGO_URI_ROOT" "$@"; }

envval() { grep "^$1=" "$PROD_ENV" | head -1 | cut -d= -f2-; }

setup() {
  if [ ! -f "$ENV_FILE" ]; then
    local pw
    pw=$(grep '^MONGO_URI=' "$PROD_ENV" | sed -E 's#.*//witness:([^@]+)@.*#\1#')
    {
      echo "BENCH_DB_PASSWORD=$pw"
      echo "BENCH_TOKEN_KEY=$(openssl rand -hex 32)"
      echo "BENCH_SECRETS_KEY=$(openssl rand -base64 32)"
      echo "ANTHROPIC_API_KEY=$(envval ANTHROPIC_API_KEY)"
      echo "OPENAI_API_KEY=$(envval OPENAI_API_KEY)"
      echo "LOCAL_LLM_BASE_URL=http://172.18.0.1:8090/v1"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "wrote $ENV_FILE"
  fi
  # Older bench.env files reused the real secrets key; replace it with a random one.
  if ! grep -q '^BENCH_SECRETS_KEY=' "$ENV_FILE"; then
    sed -i '/^SECRETS_ENCRYPTION_KEY=/d' "$ENV_FILE"
    echo "BENCH_SECRETS_KEY=$(openssl rand -base64 32)" >> "$ENV_FILE"
    echo "bench.env: switched to a random secrets key"
  fi
  local have
  have=$(mongosh_root --eval 'db.getSiblingDB("witness_bench_base").getCollectionNames().length')
  if [ "$have" = "0" ]; then
    echo "snapshotting witness_bench -> witness_bench_base"
    docker exec "$MONGO_CONTAINER" sh -c "mongodump --uri='$MONGO_URI_ROOT' --db=witness_bench --archive --quiet" |
      docker exec -i "$MONGO_CONTAINER" mongorestore --uri="$MONGO_URI_ROOT" --archive \
        --nsFrom='witness_bench.*' --nsTo='witness_bench_base.*' --drop >/dev/null 2>&1
  fi
  echo "setup ok"
}

reset() {
  # Restoring can fail transiently (e.g. while the previous bench container is still
  # closing connections). Retry, and never fail silently: a skipped case would look
  # like a case that was never run.
  local attempt log
  log=$(mktemp)
  for attempt in 1 2 3 4; do
    if docker exec "$MONGO_CONTAINER" sh -c "mongodump --uri='$MONGO_URI_ROOT' --db=witness_bench_base --archive --quiet" 2>"$log" |
        docker exec -i "$MONGO_CONTAINER" mongorestore --uri="$MONGO_URI_ROOT" --archive \
          --nsFrom='witness_bench_base.*' --nsTo='witness_bench.*' --drop >"$log" 2>&1 &&
      # Nothing in the bench may reach the outside world or run on its own.
      mongosh_root --eval '
        const b = db.getSiblingDB("witness_bench");
        ["connected_accounts","telegrambotconnections","telegramidentitylinks","telegramlinkcodes","scheduled_jobs","oauth_flow_state"]
          .forEach(c => b.getCollection(c).deleteMany({}));' >>"$log" 2>&1; then
      rm -f "$log"
      echo "bench DB reset"
      return 0
    fi
    echo "bench DB reset failed (attempt $attempt): $(tail -3 "$log" | tr '\n' ' ')" >&2
    sleep 5
  done
  rm -f "$log"
  return 1
}

up() {
  BENCH_MODEL="$1" docker compose -p bench --env-file "$ENV_FILE" -f "$HERE/docker-compose.bench.yml" up -d --force-recreate >/dev/null 2>&1
  for _ in $(seq 1 60); do
    curl -fs http://127.0.0.1:3011/health >/dev/null 2>&1 && { echo "bench agent-service up (model=$1)"; return; }
    sleep 2
  done
  echo "bench agent-service failed to start" >&2
  docker logs --tail 30 agent-service-bench >&2 || true
  exit 1
}

down() { docker compose -p bench --env-file "$ENV_FILE" -f "$HERE/docker-compose.bench.yml" down >/dev/null 2>&1 || true; }

# Records an infrastructure failure as a result, so the matrix shows it and it can
# never be mistaken for a case that simply wasn't run.
record_failure() {
  local run_id="$1" model="$2" id="$3" why="$4"
  mkdir -p "results/$run_id/$model"
  printf '{"runId":"%s","model":"%s","caseId":"%s","title":"%s","passed":0,"total":0,"checks":[],"metrics":{},"turns":[],"error":"%s"}\n' \
    "$run_id" "$model" "$id" "$id" "$why" > "results/$run_id/$model/$id.json"
  echo "== $model :: $id ... ERROR $why" >&2
}

run_one() {
  local model="$1" id="$2" run_id="$3"
  if ! reset; then record_failure "$run_id" "$model" "$id" "bench database reset failed"; return 0; fi
  if ! (up "$model"); then record_failure "$run_id" "$model" "$id" "bench agent-service failed to start"; down; return 0; fi
  set +e
  docker run --rm --network "$DOCKER_NETWORK" -v "$PWD":/bench -w /bench \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
    --env-file "$ENV_FILE" \
    -e BENCH_URL=http://agent-service-bench:3001 \
    -e BENCH_MONGO_URI="mongodb://bench:$(grep '^BENCH_DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2)@${MONGO_HOST}:27017/witness_bench?authSource=witness_bench" \
    -e BENCH_RUN_ID="$run_id" -e LLAMA_METRICS_URL="$LLAMA_METRICS_URL" -e BENCH_USER_EMAIL="$BENCH_USER_EMAIL" -e BENCH_CODE_VERSION="$BENCH_CODE_VERSION" \
    -e BENCH_SIM_MODEL="${BENCH_SIM_MODEL:-}" -e BENCH_JUDGE_MODEL="${BENCH_JUDGE_MODEL:-}" \
    node:22-slim sh -c "npm i --silent --no-audit --no-fund >/dev/null 2>&1 && node run.mjs '$model' '$id'"
  set -e
  mkdir -p "results/$run_id/$model"
  docker logs agent-service-bench > "results/$run_id/$model/service-$id.log" 2>&1 || true
  down
  [ -f "results/$run_id/$model/$id.json" ] || record_failure "$run_id" "$model" "$id" "runner produced no result"
  return 0
}

run() {
  local model="$1"; shift
  local run_id="${BENCH_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
  local ids=("$@")
  # BENCH_CASES (space separated) selects cases when none are given as arguments.
  if [ ${#ids[@]} -eq 0 ] && [ -n "${BENCH_CASES:-}" ]; then read -r -a ids <<< "$BENCH_CASES"; fi
  if [ ${#ids[@]} -eq 0 ]; then
    mapfile -t ids < <(for f in cases/*.json; do basename "$f" .json; done)
  fi
  # Every case starts from a pristine DB and a fresh service, so cases can't affect each other.
  for id in "${ids[@]}"; do run_one "$model" "$id" "$run_id"; done
  # Every case must have a result (a real one or a recorded failure).
  local missing=0
  for id in "${ids[@]}"; do
    [ -f "results/$run_id/$model/$id.json" ] || { echo "MISSING result: $model / $id" >&2; missing=1; }
  done
  echo "run id: $run_id ($model: ${#ids[@]} case(s))"
  return $missing
}

case "${1:-}" in
  setup) setup ;;
  reset) reset ;;
  run) shift; run "$@" ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
