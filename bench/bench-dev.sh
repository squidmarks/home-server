#!/usr/bin/env bash
# Development benchmark for the Investment Studio. Run on the box.
#   ./bench-dev.sh run <model> [case ...]   fresh studio + empty database per case
#
# For every case: drop the benchmark_run database, start a new studio agent-service
# on <model>, run the case (simulated user, rules, judge; the runner also resets the
# paper account), save the results and the service log, stop the studio.
# Results land in results/<runId>/<label>/<case>.json, where <label> is the model, plus
# BENCH_LABEL_SUFFIX when it is run under non-default inference settings:
#   BENCH_LABEL_SUFFIX=effort-low BENCH_KWARGS='{"reasoning_effort":"low"}' \
#   BENCH_INFERENCE_JSON='{...}' ./bench-dev.sh run local-qwen3.8-27b inv-order-sizer
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
cd "$BENCH_DIR"
ENV_FILE=$ENV_DIR/benchmark-run.env
COMPOSE=(docker compose -p benchmark-run --env-file "$ENV_FILE" -f "$STUDIOS_DIR/investment-run.yml")
MONGO_ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
MONGO_URI_ROOT="mongodb://root:${MONGO_ROOT_PW}@localhost:27017/?authSource=admin"
GUIDANCE_DIR=$AGENT_STUDIO_DIR/profiles/benchmark/engine/src/context

reset_db() {
  docker exec "$MONGO_CONTAINER" mongosh --quiet "$MONGO_URI_ROOT" --eval 'db.getSiblingDB("benchmark_run").dropDatabase()' >/dev/null
  mkdir -p "$RUN_STATE_DIR" && rm -f "$RUN_STATE_DIR/KILL" "$RUN_STATE_DIR/faults.json"
}

up() {
  BENCH_MODEL="$1" LOCAL_LLM_CHAT_TEMPLATE_KWARGS="${BENCH_KWARGS:-}" \
  RUNTIME_CLOCK_ISO="${RUNTIME_CLOCK_ISO:-}" "${COMPOSE[@]}" up -d --force-recreate >/dev/null 2>&1
  for _ in $(seq 1 60); do
    curl -fs http://127.0.0.1:3511/health >/dev/null 2>&1 && { echo "studio up (router model $1)"; return; }
    sleep 2
  done
  echo "studio failed to start" >&2
  docker logs --tail 30 agent-service-run >&2 || true
  return 1
}

down() { "${COMPOSE[@]}" down >/dev/null 2>&1 || true; }

# Keep the run's database with its other artifacts, so the run can be loaded into a
# studio later (see inspect.sh). The dump is a few hundred KB.
archive_db() {
  local out="results/$1/$2/$3.mongo.gz"
  if docker exec "$MONGO_CONTAINER" mongodump --uri="$MONGO_URI_ROOT" --db=benchmark_run --archive --gzip > "$out" 2>/dev/null && [ -s "$out" ]; then
    [ -f "results/$1/$2/$3.json" ] && python3 - "results/$1/$2/$3.json" "$3.mongo.gz" <<'PY'
import json, sys
path, name = sys.argv[1:3]
d = json.load(open(path)); d["archive"] = name
json.dump(d, open(path, "w"), indent=2)
PY
  else
    echo "warning: could not archive the run database for $2 / $3" >&2
    rm -f "$out"
  fi
}

record_failure() {
  local run_id="$1" model="$2" id="$3" why="$4"
  mkdir -p "results/$run_id/$model"
  printf '{"runId":"%s","model":"%s","caseId":"%s","title":"%s","suite":"investment","passed":0,"total":0,"checks":[],"metrics":{},"turns":[],"error":"%s"}\n' \
    "$run_id" "$model" "$id" "$id" "$why" > "results/$run_id/$model/$id.json"
  echo "== $model :: $id ... ERROR $why" >&2
}

run_one() {
  local model="$1" id="$2" run_id="$3"
  local label="$model${BENCH_LABEL_SUFFIX:+--$BENCH_LABEL_SUFFIX}"

  # What the model server is actually running, recorded with the result. Only for a
  # local model: a hosted one is not served from this box, and stamping the local
  # server's flags on it would be a lie. If the job asked for a profile and the
  # server is on another (someone switched it by hand mid-job), stop rather than
  # mislabel every case after it.
  # One URL for either engine. The shim proxies to whichever is holding the card
  # and, more to the point, returns the same metrics shape for both -- llama.cpp
  # reports its own timings in the body, vLLM reports only engine-wide counters,
  # and the studio should not have to know the difference. It also measures what
  # the call drew at the wall, which no engine can.
  export LOCAL_LLM_BASE_URL="$SHIM_BASE_URL"

  # Whichever local model a case asks for, the card must actually be holding it.
  # One card holds one model and loading another takes minutes, so a run started
  # against the wrong resident model would otherwise produce a full set of
  # results attributed to a model that never saw a single token. The shim
  # answers with what the ENGINE reports, so a stale name file cannot satisfy
  # this. Hosted models never reach here.
  case "$model" in local-*)
    shim_admin="$SHIM_ADMIN_URL"
    shim_status=$(curl -s -m 8 "$shim_admin/admin/status" 2>/dev/null || echo "")
    shim_model=$(printf '%s' "$shim_status" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("model") or "")
except Exception: print("")' 2>/dev/null || echo "")
    if [ -z "$shim_status" ]; then
      record_failure "$run_id" "$label" "$id" "the inference shim is not answering; nothing can have served this case"
      return 0
    fi
    if [ "$shim_model" != "$model" ]; then
      record_failure "$run_id" "$label" "$id" "the card is holding ${shim_model:-no model}, but this case asked for $model"
      return 0
    fi
    # And the card must be IDLE. A studio on this box -- a scheduled agent, a
    # chat session -- shares the GPU, and a case measured against contention
    # reports latencies that describe two workloads. The shim flags its own
    # metrics "shared" when that happens, but only the ENERGY is suppressed:
    # wall-clock, TTFT and tok/s are recorded as if the run had the machine.
    # Settle briefly first, because the previous case's last response can still
    # be draining when this one starts.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      inflight=$(curl -s -m 8 "$shim_admin/admin/status" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("inFlight") or 0)
except Exception: print(0)' 2>/dev/null || echo 0)
      [ "${inflight:-0}" -eq 0 ] && break
      sleep 3
    done
    if [ "${inflight:-0}" -ne 0 ]; then
      record_failure "$run_id" "$label" "$id" "the GPU has ${inflight} request(s) in flight from something else; a timing measured against contention is not this model's"
      return 0
    fi
  ;; esac

  # What served the case, as the shim observes it: the running engine, its
  # profile and its health. One witness for every local model -- the profile
  # scripts' name files were consulted before, and once said vLLM was down while
  # it was serving. Hosted models are not served from the inference box, so
  # stamping its state on them would be a lie.
  local server_json="" observed=""
  case "$model" in local-*)
    server_json=$("$HERE/shim.py" describe 2>/dev/null || echo "")
    observed=$(printf '%s' "$server_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("profile","") or "")
except Exception: print("")' 2>/dev/null || echo "")
    # Health first: an engine that does not answer cannot have produced anything.
    if [ "$(printf '%s' "$server_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("health",""))
except Exception: print("")' 2>/dev/null)" != "up" ]; then
      record_failure "$run_id" "$label" "$id" "the inference engine is not answering; nothing can have served this case"
      return 0
    fi
    if [ -n "${BENCH_EXPECT_PROFILE:-}" ] && [ "$observed" != "$BENCH_EXPECT_PROFILE" ]; then
      record_failure "$run_id" "$label" "$id" "the engine is on profile ${observed:-unknown}, but this condition asked for $BENCH_EXPECT_PROFILE"
      return 0
    fi
  ;; esac

  if ! reset_db; then record_failure "$run_id" "$label" "$id" "could not reset the benchmark database"; return 0; fi
  if ! (up "$model"); then record_failure "$run_id" "$label" "$id" "studio failed to start"; down; return 0; fi
  set +e
  docker run --rm --name bench-runner --network "$DOCKER_NETWORK" -v "$PWD":/bench -v "$GUIDANCE_DIR":/guidance:ro -w /bench \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
    --env-file "$ENV_FILE" \
    -e BENCH_URL=http://agent-service-run:3001 \
    -e BENCH_MONGO_URI="mongodb://benchmark_run:$(grep '^BENCHMARK_RUN_DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2)@${MONGO_HOST}:27017/benchmark_run?authSource=admin" \
    -e BENCH_RUN_ID="$run_id" -e GUIDANCE_DIR=/guidance -e BENCH_CODE_VERSION="$BENCH_CODE_VERSION" \
    -e BENCH_MODEL_LABEL="$label" -e BENCH_INFERENCE_JSON="${BENCH_INFERENCE_JSON:-}" \
    -e BENCH_SERVER_JSON="$server_json" \
    -e BENCH_REPLAY_FROM="${BENCH_REPLAY_FROM:-}" \
    -e BENCH_SIM_MODEL="${BENCH_SIM_MODEL:-}" -e BENCH_JUDGE_MODEL="${BENCH_JUDGE_MODEL:-}" \
    -e BENCH_TIMEOUT_MINUTES="${BENCH_TIMEOUT_MINUTES:-}" \
    -e SHELLY_URL="${SHELLY_URL:-}" -e POWER_RATE_PER_KWH="${POWER_RATE_PER_KWH:-}" \
    -e POWER_IDLE_WATTS="${POWER_IDLE_WATTS:-}" \
    node:22-slim sh -c "npm i --silent --no-audit --no-fund >/dev/null 2>&1 && node run-dev.mjs '$model' '$id'"
  set -e
  mkdir -p "results/$run_id/$label"
  docker logs agent-service-run > "results/$run_id/$label/service-$id.log" 2>&1 || true
  archive_db "$run_id" "$label" "$id"
  down
  reset_db || true   # leave the throwaway studio empty
  [ -f "results/$run_id/$label/$id.json" ] || record_failure "$run_id" "$label" "$id" "runner produced no result"
  return 0
}

run() {
  local model="$1"; shift
  local run_id="${BENCH_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
  local ids=("$@")
  if [ ${#ids[@]} -eq 0 ] && [ -n "${BENCH_CASES:-}" ]; then read -r -a ids <<< "$BENCH_CASES"; fi
  if [ ${#ids[@]} -eq 0 ]; then
    mapfile -t ids < <(grep -l '"suite": "investment"' cases/*.json | while read -r f; do basename "$f" .json; done)
  fi
  for id in "${ids[@]}"; do run_one "$model" "$id" "$run_id"; done
  local missing=0
  local label="$model${BENCH_LABEL_SUFFIX:+--$BENCH_LABEL_SUFFIX}"
  for id in "${ids[@]}"; do
    [ -f "results/$run_id/$label/$id.json" ] || { echo "MISSING result: $label / $id" >&2; missing=1; }
  done
  echo "run id: $run_id ($label: ${#ids[@]} case(s))"
  return $missing
}

case "${1:-}" in
  run) shift; run "$@" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
