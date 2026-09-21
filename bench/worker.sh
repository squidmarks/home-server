#!/usr/bin/env bash
# Job worker: runs benchmark jobs that the bench UI queues, one at a time (the
# bench database is shared, so runs can never overlap).
#   queue:   $JOBS_DIR/queue/<id>.json     {id, type: "run"|"rejudge", ...}
#   status:  $JOBS_DIR/status/<id>.json    {state: queued|running|done|failed, ...}
#   logs:    $JOBS_DIR/logs/<id>.log
JOBS_DIR="${JOBS_DIR:-$HOME/infra/bench-ui-data/jobs}"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
cd "$HERE"
mkdir -p "$JOBS_DIR"/{queue,status,logs}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
setstate() { # id state [extra-json-object]
  python3 - "$JOBS_DIR/status/$1.json" "$2" "${3:-{\}}" <<'PY'
import json,sys,os
p,state,extra=sys.argv[1:4]
d=json.load(open(p)) if os.path.exists(p) else {}
d["state"]=state; d.update(json.loads(extra))
json.dump(d,open(p+".tmp","w")); os.replace(p+".tmp",p)
PY
}
field() { python3 -c "import json,sys;d=json.load(open('$1'));v=d.get('$2','');print(' '.join(v) if isinstance(v,list) else v)"; }

run_job() {
  local f="$1" id type; id=$(basename "$f" .json); type=$(field "$f" type)
  local log="$JOBS_DIR/logs/$id.log"
  setstate "$id" running "{\"startedAt\":\"$(now)\"}"
  local rc=0
  if [ "$type" = "rejudge" ]; then
    local run judge targets; run=$(field "$f" run); judge=$(field "$f" judge); targets=$(field "$f" targets)
    docker run --rm -v "$BENCH_DIR":/bench -w /bench --user "$(id -u):$(id -g)" -e HOME=/tmp \
      --env-file "$ENV_DIR/bench.env" node:22-slim node rejudge.mjs "$judge" "$run" $targets >"$log" 2>&1 || rc=$?
  else
    local runner=./run_all.sh
    [ "$(field "$f" suite)" = "investment" ] && runner=./run_dev_all.sh
    # One pass of the cases per inference condition (a job without any is one default pass).
    local conds; conds=$(python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d.get("conditions") or [{}]:
    st=c.get("settings") or {}
    info={**st,"server":d.get("serverLabel") or None,"description":c.get("description") or "server defaults"} if c.get("suffix") else None
    print(json.dumps({"suffix":c.get("suffix",""),"kwargs":json.dumps(c["kwargs"]) if c.get("kwargs") else "","info":json.dumps(info) if info else ""}))
PY
)
    while IFS= read -r cond; do
      local suffix kwargs info
      suffix=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['suffix'])" "$cond")
      kwargs=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['kwargs'])" "$cond")
      info=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['info'])" "$cond")
      echo ">>> inference: ${suffix:-server defaults}" >>"$log"
      BENCH_RUN_ID=$(field "$f" run) BENCH_CASES=$(field "$f" cases) \
      BENCH_SIM_MODEL=$(field "$f" simulator) BENCH_JUDGE_MODEL=$(field "$f" judge) \
      BENCH_LABEL_SUFFIX="$suffix" BENCH_KWARGS="$kwargs" BENCH_INFERENCE_JSON="$info" \
        $runner $(field "$f" models) >>"$log" 2>&1 || rc=$?
    done <<< "$conds"
  fi
  mv "$f" "$JOBS_DIR/queue/$id.json.done"
  if [ $rc -eq 0 ]; then setstate "$id" done "{\"finishedAt\":\"$(now)\"}"; else setstate "$id" failed "{\"finishedAt\":\"$(now)\",\"exitCode\":$rc}"; fi
}

echo "worker watching $JOBS_DIR/queue"
while true; do
  next=$(ls -1 "$JOBS_DIR"/queue/*.json 2>/dev/null | head -1)
  if [ -n "$next" ]; then
    # Never overlap with a run started by hand.
    while pgrep -f "run_all.sh|run_dev_all.sh|bench.sh run|bench-dev.sh run" >/dev/null; do sleep 15; done
    run_job "$next"
  else
    sleep 5
  fi
done
