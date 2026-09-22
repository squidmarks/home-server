#!/usr/bin/env bash
# Run one measurement tool and record what it said, verbatim.
#
#   ./probe-run.sh <runId> <tool> <profile> [tool args...]
#
# This deliberately contains no stopwatch. Every number here comes from a tool
# that already exists, because the hand-rolled probe this replaces measured the
# wrong things twice: it sent stream:false, so what it reported as "prefill" was
# prompt_ms and it could not time a first token at all, and a ranking taken from
# it was used to pick a server profile that a real case comparison then
# contradicted. Orchestration is ours -- the lock, the profile switch, the
# read-back, the stamp. The measuring is not.
#
# The two tools want opposite things, which is the whole reason this wrapper
# exists rather than a line in a README:
#
#   llama-bench   loads ITS OWN copy of the model, so llama-server must be STOPPED
#                 or they fight over ~21 GiB of VRAM. Bare-model characterisation:
#                 prompt/generation rate at depth (-d), ubatch, KV cache type.
#   speed-bench   is a client against the RUNNING llama-server, so the server must
#                 be UP. Measures the server as the studio actually talks to it,
#                 and reports draft acceptance, which is what speculative decoding
#                 lives or dies by.
#
# Results land in probes/, a sibling of results/, so a measurement can never be
# read as a graded run or find its way into a mean.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

RUN_ID="${1:?run id}"; TOOL="${2:?tool (llama-bench|speed-bench)}"; PROFILE="${3:-}"
shift 3 || shift $#

PROFILES="$HERE/../llama/profiles.sh"
OUT_DIR="$BENCH_DIR/probes/$RUN_ID"
mkdir -p "$OUT_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$OUT_DIR/$TOOL-$STAMP.json"

# Whatever happens, put the server back. A probe that leaves llama-server down
# would strand every job behind it, and the failure would look like the next
# job's fault rather than this one's.
restore() {
  if [ "$TOOL" = "llama-bench" ] && [ -n "$RESTORE_TO" ]; then
    echo ">>> restoring the model server to $RESTORE_TO" >&2
    "$PROFILES" set "$RESTORE_TO" >&2 || echo "!! COULD NOT RESTORE $RESTORE_TO" >&2
  fi
}
RESTORE_TO=""
trap restore EXIT

# The profile to measure under, set and then read back rather than assumed.
if [ -n "$PROFILE" ]; then
  "$PROFILES" set "$PROFILE" >&2 || { echo "!! could not switch to profile $PROFILE" >&2; exit 3; }
fi
OBSERVED=$("$PROFILES" describe 2>/dev/null || echo "{}")
RUNNING=$(printf '%s' "$OBSERVED" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("profile",""))
except Exception: print("")' 2>/dev/null || echo "")
if [ -n "$PROFILE" ] && [ "$RUNNING" != "$PROFILE" ]; then
  echo "!! asked for profile $PROFILE but the server reports ${RUNNING:-unknown}" >&2
  exit 3
fi

rc=0
case "$TOOL" in
  llama-bench)
    RESTORE_TO="${RUNNING:-$PROFILE}"
    [ -n "$RESTORE_TO" ] || { echo "!! llama-bench stops the server, so a profile is required to restore it" >&2; exit 2; }
    MODEL=$(printf '%s' "$OBSERVED" | python3 -c 'import json,sys,shlex
try: print(shlex.split(json.load(sys.stdin).get("execStart",""))[2])
except Exception: print("")' 2>/dev/null || echo "")
    [ -n "$MODEL" ] || { echo "!! could not read the model path from the running unit" >&2; exit 2; }
    echo ">>> stopping llama-server so llama-bench can have the GPU" >&2
    sudo systemctl stop llama-server >&2 || true
    RAW=$("$HOME/llama.cpp/build/bin/llama-bench" -m "$MODEL" -o json "$@" 2>/dev/null) || rc=$?
    ;;
  speed-bench)
    SB="$HOME/llama.cpp/tools/server/bench/speed-bench/speed_bench.py"
    [ -f "$SB" ] || { echo "!! speed-bench not found at $SB" >&2; exit 2; }
    RAW=$(python3 "$SB" --url "${LLAMA_HOST:-172.18.0.1}:${LLAMA_PORT:-8090}" "$@" 2>/dev/null) || rc=$?
    ;;
  *) echo "!! unknown tool: $TOOL (llama-bench|speed-bench)" >&2; exit 2 ;;
esac

# The tool's own output verbatim, plus what it was measured under. Verbatim
# because re-shaping a measurement is how a measurement stops being one; if the
# tool emits something we cannot parse, that is recorded rather than dropped.
RUN_ID="$RUN_ID" TOOL="$TOOL" ARGS="$*" RAW="${RAW:-}" OBSERVED="$OBSERVED" RC="$rc" \
CODE="${BENCH_CODE_VERSION:-unknown}" OUT="$OUT" python3 -c '
import json, os, datetime
e = os.environ
try: raw = json.loads(e["RAW"])
except Exception: raw = {"unparsed": e["RAW"][:20000]}
json.dump({
  "kind": "probe",                      # never a score: nothing here grades a model
  "runId": e["RUN_ID"], "tool": e["TOOL"], "args": e["ARGS"],
  "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "exitCode": int(e["RC"]),
  "code": {"version": e["CODE"]},
  "server": json.loads(e["OBSERVED"]) if e["OBSERVED"].strip().startswith("{") else None,
  "output": raw,
}, open(e["OUT"], "w"), indent=2)
' 2>/dev/null || { echo "!! could not write $OUT" >&2; exit 1; }

echo "probe written to $OUT (exit $rc)" >&2
exit $rc
