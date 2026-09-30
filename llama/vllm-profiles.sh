#!/usr/bin/env bash
# The vLLM side of profiles.sh: named configurations, set and read back.
#
#   ./vllm-profiles.sh list            the names, and what is running now
#   ./vllm-profiles.sh set long-mtp    restart vLLM under that configuration
#   ./vllm-profiles.sh label           the running configuration's name
#   ./vllm-profiles.sh describe        JSON for a result to record
#
# llama.cpp gets its profiles from flags on one binary; vLLM gets them from
# environment the radiance launcher reads. Either way a run must be able to say
# what produced it -- a result stamped with a name nobody verified is the
# mistake ADR-0016 exists about, so `describe` reports what the SERVER answers
# with, not what we asked for.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VLLM_DIR="${VLLM_DIR:-$HOME/radiance-vllm-mxfp4}"
NAME_FILE="${VLLM_NAME_FILE:-$HOME/.cache/radiance-mxfp4/profile-name}"
BASE="${VLLM_BASE_URL:-http://127.0.0.1:8080}"
# The container THIS script starts. Another engine can hold the port.
VLLM_NAME="${VLLM_CONTAINER:-vllmmxfp4074}"

# Each profile is the environment the launcher needs. SPEC_METHOD picks the
# drafter, SPEC its depth, and the shape trio decides how much context is
# reserved and how large a prefill chunk is processed at once.
profile_env() {
  case "$1" in
    # What we have been running: the long-context single-GPU shape.
    long-dflash)  echo "SPEC_METHOD=dflash SPEC=7 MAXSEQS=3 CHUNK=2560 MAXLEN=220000" ;;
    # The same shape with the MTP head instead of the block-diffusion drafter.
    long-mtp)     echo "SPEC_METHOD=mtp SPEC=4 MAXSEQS=3 CHUNK=2560 MAXLEN=220000" ;;
    # ctx128k-chunk4096 is short-dflash with ONLY the context changed, so it stays
    # attributable -- the earlier shape comparison moved context AND chunk together
    # and gained 8% that could not be assigned to either. Added 2026-09-29, when
    # llama.cpp went to the model's full 262144 and left vLLM the shortest of the
    # three at 65536. KV is ~45.6 KB/token at fp8 (measured: 4.7 GiB holding 107,887
    # tokens), so 131072 needs ~5.7 GiB. calibrate-kv sizes that per shape; vLLM
    # refuses to start if the cache cannot hold one whole sequence, so a failed
    # start here means the KV budget needs recalibrating, not that 128K is out.
    # 64K is well above the 42,860-token peak this workload has ever reached,
    # and buys a 4096 prefill chunk. This is calibrate-kv's own TP=1 default.
    short-dflash) echo "SPEC_METHOD=dflash SPEC=7 MAXSEQS=8 CHUNK=4096 MAXLEN=65536" ;;
    short-mtp)    echo "SPEC_METHOD=mtp SPEC=4 MAXSEQS=8 CHUNK=4096 MAXLEN=65536" ;;
    # Chunk against context, held apart. The first shape comparison moved BOTH
    # (220K/2560 against 64K/4096) and gained 8% that cannot be attributed to
    # either. If the chunk is what matters, the long context is free.
    ctx64k-chunk2560)  echo "SPEC_METHOD=dflash SPEC=7 MAXSEQS=8 CHUNK=2560 MAXLEN=65536" ;;
    ctx64k-chunk4096)  echo "SPEC_METHOD=dflash SPEC=7 MAXSEQS=8 CHUNK=4096 MAXLEN=65536" ;;
    ctx64k-chunk8192)  echo "SPEC_METHOD=dflash SPEC=7 MAXSEQS=8 CHUNK=8192 MAXLEN=65536" ;;
    ctx128k-chunk4096) echo "SPEC_METHOD=dflash SPEC=7 MAXSEQS=8 CHUNK=4096 MAXLEN=131072" ;;
    ctx220k-chunk4096) echo "SPEC_METHOD=dflash SPEC=7 MAXSEQS=8 CHUNK=4096 MAXLEN=220000" ;;
    # Draft-depth sweep on the short shape, where prefill is not the bottleneck.
    short-dflash-3)  echo "SPEC_METHOD=dflash SPEC=3 MAXSEQS=8 CHUNK=4096 MAXLEN=65536" ;;
    short-dflash-5)  echo "SPEC_METHOD=dflash SPEC=5 MAXSEQS=8 CHUNK=4096 MAXLEN=65536" ;;
    short-dflash-9)  echo "SPEC_METHOD=dflash SPEC=9 MAXSEQS=8 CHUNK=4096 MAXLEN=65536" ;;
    # There is deliberately no "no speculation" profile: this launcher always
    # builds a speculative config and accepts only dflash or mtp. Asking for
    # anything else fails deep inside engine compilation, minutes later, with a
    # torch error that says nothing about the cause.
    *) return 1 ;;
  esac
}
PROFILES="long-dflash short-dflash short-dflash-3 short-dflash-5 short-dflash-9 ctx64k-chunk2560 ctx64k-chunk4096 ctx64k-chunk8192 ctx128k-chunk4096 ctx220k-chunk4096 long-mtp short-mtp"

# Up means OUR container is serving, not that something answers on the port.
# serve-sly.sh took 8080 on 2026-09-30 and this reported "short-dflash (up)" for
# an engine that had been stopped for hours -- the name file was believed
# because the health check passed, and the health check passed because a
# different engine was answering. A benchmark labelled with the wrong engine is
# exactly what the header of this file says must not happen.
running() {
  docker ps -q --filter "name=^${VLLM_NAME}$" 2>/dev/null | grep -q . || { echo down; return; }
  curl -s -m 3 "$BASE/health" >/dev/null 2>&1 && echo up || echo down
}
# The name we last set, but only while the engine it describes is the one up.
# Empty means "nothing of ours is running", which callers must treat as needing
# a switch rather than as a match.
current_name() {
  [ "$(running)" = up ] || return 0
  cat "$NAME_FILE" 2>/dev/null
}

case "${1:-list}" in
  list)
    echo "profiles: $PROFILES"
    _n=$(current_name); echo "running:  ${_n:-unknown} ($(running))"
    ;;
  label) current_name ;;
  flags) profile_env "${2:?profile}" || { echo "unknown profile: $2" >&2; exit 2; } ;;
  describe)
    # What the server actually answers with, plus the name we last set. The two
    # are reported side by side on purpose: if they disagree, the result says so.
    served=$(curl -s -m 3 "$BASE/v1/models" 2>/dev/null | python3 -c '
import json,sys
try: print(",".join(m["id"] for m in json.load(sys.stdin).get("data",[])))
except Exception: print("")' 2>/dev/null)
    python3 - "$(current_name)" "$served" "$(running)" <<'PY'
import json,sys
name, served, health = (sys.argv[1:4] + ["","",""])[:3]
print(json.dumps({"engine":"vllm","profile":name or None,
                  "served":[s for s in served.split(",") if s],"health":health}))
PY
    ;;
  set)
    want="${2:?profile}"
    env_line=$(profile_env "$want") || { echo "unknown profile: $want (have: $PROFILES)" >&2; exit 2; }
    echo ">>> vLLM profile $want: $env_line"
    docker stop vllmmxfp4074 >/dev/null 2>&1 || true
    # Wait for the card to actually let go. `docker stop` returns when the
    # container is gone, not when ~19 GiB of VRAM is free, and starting the next
    # engine into a still-occupied card fails minutes later inside engine init
    # with a traceback that names nothing. That lost the mtp arm of one sweep.
    for _ in $(seq 1 30); do
      used=$(rocm-smi --showmemuse 2>/dev/null | grep -oE "VRAM%\): [0-9]+" | grep -oE "[0-9]+$" | head -1)
      [ -z "$used" ] && break
      [ "$used" -lt 5 ] && break
      sleep 2
    done
    mkdir -p "$(dirname "$NAME_FILE")"
    # Cleared now, written only once the server actually answers. Writing it up
    # front was worse in both directions: a failed start left the file claiming
    # a profile nothing was running, the next repeat saw a matching label and
    # skipped its switch, and cases then ran against a dead engine while every
    # check said the profile was correct.
    : > "$NAME_FILE"
    # Keep the launcher's output. Discarding it and printing "!! launcher
    # failed" hid a plain, correctly-worded error ("port 8080 is already in
    # use") behind a message that said nothing, and the caller -- the shim's
    # admin page, or a sweep -- had no way to find out what went wrong.
    out=$(cd "$VLLM_DIR" && env $env_line DETACH=1 ./serve-tp1.sh \
        --override-generation-config '{"temperature":0}' \
        --served-model-name Qwen3.8 Qwen3.6 Qwen3.8-MXFP4 local-qwen3.8-27b-mxfp4 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "!! launcher failed (exit $rc):"
      printf '%s\n' "$out" | tail -20
      exit 3
    fi
    # Watch the container as well as the endpoint. A bad configuration dies in
    # engine compilation and never answers /health, so waiting only on health
    # burns the full timeout on a failure that was already decided.
    for _ in $(seq 1 90); do
      [ "$(running)" = up ] && { printf '%s' "$want" > "$NAME_FILE"; echo ">>> vLLM up on $want"; exit 0; }
      if ! docker ps -q --filter name=vllmmxfp4074 | grep -q .; then
        echo "!! vLLM exited while starting on $want; last lines:" >&2
        docker logs --tail 15 vllmmxfp4074 2>&1 | tail -15 >&2
        exit 5
      fi
      sleep 10
    done
    echo "!! vLLM did not become healthy within 15 minutes" >&2; exit 4
    ;;
  *) echo "usage: $0 list|label|flags <p>|describe|set <p>" >&2; exit 2 ;;
esac
