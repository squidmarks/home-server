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
  # Claim the job before running it: if this worker is restarted mid-job (a deploy,
  # a reboot), the job must not be picked up and run a second time.
  local claim="$JOBS_DIR/queue/$id.json.taken"
  mv "$f" "$claim" || return 0
  f="$claim"
  setstate "$id" running "{\"startedAt\":\"$(now)\"}"
  local rc=0
  if [ "$type" = "probe" ] && [ ! -x "$HERE/../llama/profiles.sh" -o -n "$INFERENCE_FQDN" ]; then
    # llama-bench loads its own copy of the model onto the card and speed-bench
    # times llama-server from beside it: a probe measures the GPU box itself, so
    # it can only run there (bench/probe-run.sh on the inference box).
    echo "probe jobs measure the GPU directly and run on the inference box, not here: run bench/probe-run.sh there" >"$log"
    rc=1
  elif [ "$type" = "probe" ]; then
    # A measurement. The worker runs it for the same reason it runs everything
    # else: it holds the job, so nothing else can be touching the model server.
    # That exclusivity is the whole point -- a nine-profile sweep run by hand on
    # 2026-09-22 switched llama-server eight times beside a live worker and only
    # got away with it because the queue happened to be empty.
    local tool profile args
    tool=$(field "$f" tool); profile=$(field "$f" profile); args=$(field "$f" args)
    "$HERE/probe-run.sh" "$(field "$f" run)" "$tool" "$profile" $args >"$log" 2>&1 || rc=$?
  elif [ "$type" = "rejudge" ]; then
    local run judge targets; run=$(field "$f" run); judge=$(field "$f" judge); targets=$(field "$f" targets)
    docker run --rm -v "$BENCH_DIR":/bench -w /bench --user "$(id -u):$(id -g)" -e HOME=/tmp \
      --env-file "$ENV_DIR/bench.env" node:22-slim node rejudge.mjs "$judge" "$run" $targets >"$log" 2>&1 || rc=$?
  else
    # One clock for the whole job. The studio stamps the current time into every
    # turn, so without this two cells minutes apart send different input and a
    # deterministic model answers differently -- which is what made repeats
    # incomparable. Fixed per job, so every condition in a comparison sees the
    # same "now" and the only thing that differs is what the job is varying.
    export RUNTIME_CLOCK_ISO="${RUNTIME_CLOCK_ISO:-$(now)}"
    echo ">>> runtime clock pinned to $RUNTIME_CLOCK_ISO" >>"$log"
    # The bench studio the job targets (ADR-0020); older jobs only say `suite`.
    local studio; studio=$(field "$f" studio); [ -n "$studio" ] || studio=$(field "$f" suite)
    local runner=./run_all.sh
    [ "$studio" = "investment" ] && runner=./run_dev_all.sh
    # One pass of the cases per inference condition (a job without any is one default pass).
    local conds; conds=$(python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for c in d.get("conditions") or [{}]:
    st=c.get("settings") or {}
    info={**st,"server":d.get("serverLabel") or None,"description":c.get("description") or "server defaults"} if c.get("suffix") else None
    print(json.dumps({"suffix":c.get("suffix",""),"kwargs":json.dumps(c["kwargs"]) if c.get("kwargs") else "","info":json.dumps(info) if info else "","profile":st.get("profile","")}))
PY
)
    while IFS= read -r cond; do
      local suffix kwargs info
      suffix=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['suffix'])" "$cond")
      kwargs=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['kwargs'])" "$cond")
      info=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['info'])" "$cond")
      profile=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['profile'])" "$cond")
      echo ">>> inference: ${suffix:-server defaults}" >>"$log"
      # The worker is the only thing that may restart the model server: it holds the
      # job, so nothing else can be running a case. Conditions arrive grouped by
      # profile, so this reloads the model as rarely as the job allows.
      # Through the shim, which applies the profile to whichever engine is
      # running and reports what that engine observes (not a name file), so
      # this works from any box. bench-dev.sh reads it back before every case.
      local switcher="$HERE/shim.py"
      if [ -n "$profile" ] && [ "$profile" != "$("$switcher" label 2>/dev/null)" ]; then
        echo ">>> switching the model server to profile $profile" >>"$log"
        if ! "$switcher" set "$profile" >>"$log" 2>&1; then
          echo "!! could not switch to profile $profile; skipping this condition" >>"$log"
          rc=1
          continue
        fi
      fi
      BENCH_STUDIO="$studio" BENCH_RUN_ID=$(field "$f" run) BENCH_CASES=$(field "$f" cases) \
      BENCH_SIM_MODEL=$(field "$f" simulator) BENCH_JUDGE_MODEL=$(field "$f" judge) \
      BENCH_LABEL_SUFFIX="$suffix" BENCH_KWARGS="$kwargs" BENCH_INFERENCE_JSON="$info" \
      BENCH_EXPECT_PROFILE="$profile" BENCH_REPLAY_FROM="$(field "$f" replayFrom)" \
      BENCH_TIMEOUT_MINUTES="$(field "$f" timeoutMinutes)" \
        $runner $(field "$f" models) >>"$log" 2>&1 || rc=$?
    done <<< "$conds"
  fi
  mv "$f" "$JOBS_DIR/queue/$id.json.done"
  if [ $rc -eq 0 ]; then setstate "$id" done "{\"finishedAt\":\"$(now)\"}"; else setstate "$id" failed "{\"finishedAt\":\"$(now)\",\"exitCode\":$rc}"; fi
}

# A job still claimed at startup was interrupted (the worker died or was restarted).
# Say so rather than silently leaving it as "running" forever, and never re-run it.
for taken in "$JOBS_DIR"/queue/*.json.taken; do
  [ -e "$taken" ] || continue
  id=$(basename "$taken" .json.taken)
  echo "job $id was interrupted; leaving it stopped" >&2
  setstate "$id" failed "{\"finishedAt\":\"$(now)\",\"note\":\"the worker was restarted while this job was running\"}"
  mv "$taken" "$JOBS_DIR/queue/$id.json.done"
done

# A run writes a live file and keeps stamping it; the UI calls one "no heartbeat"
# once it is more than 60 s old (scripts/bench/lib/live.mjs, staleMs) and shows it
# in red. Nothing ever removed them, so a runner that died without cleaning up --
# a power cut on 2026-09-29, a `docker stop bench-runner` to abort a misconfigured
# run the same day -- left a red row that only went away when someone noticed and
# deleted the file by hand. Two of them accumulated in one day.
#
# Sweeping on startup is safe because the worker is restarting: nothing it started
# is still running. Staleness is still checked rather than clearing the directory,
# because the loop below tolerates runs started BY HAND (see the pgrep guard), and
# one of those may legitimately be beating right now.
LIVE_DIR="${LIVE_DIR:-$BENCH_DIR/results/.live}"
if [ -d "$LIVE_DIR" ]; then
  swept=0
  for lf in "$LIVE_DIR"/*.json; do
    [ -e "$lf" ] || continue
    age=$(( $(date +%s) - $(stat -c %Y "$lf") ))
    if [ "$age" -gt 60 ]; then
      echo "sweeping stale live file (${age}s since last heartbeat): $(basename "$lf")" >&2
      rm -f "$lf" && swept=$((swept + 1))
    fi
  done
  [ "$swept" -gt 0 ] && echo "swept $swept stale live file(s)" >&2
fi

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
