#!/usr/bin/env bash
# The local model server (llama.cpp) as a set of named profiles, so a benchmark run
# can say which one produced it and switching between them is one command.
#
#   ./profiles.sh list             the modifiers, and what is running now
#   ./profiles.sh set mtp3         write the unit, restart, wait for the model to load
#   ./profiles.sh flags mtp3       print the flags a name would produce (changes nothing)
#   ./profiles.sh label            print the running profile's name
#   ./profiles.sh describe         JSON: what is running now, for a result to record
#
# A profile name is its modifiers joined by "-", so they compose and an A/B can
# change one thing at a time:
#
#   model       q6           Qwen3.8-27B at Q6_K instead of Q4_K_M
#               moe          Qwen3.6-35B-A3B, a different model (and a different alias)
#   speculate   mtp2|3|5     the MTP draft head, --spec-draft-n-max 2/3/5
#               ngram        ngram-mod
#   thinking    nopreserve   --no-reasoning-preserve (don't resend earlier thinking)
#   prefill     cachereuse   --cache-reuse 256: reuse a common prefix by KV shifting
#               ctx32k|64k   a smaller KV allocation than the 128K default
#               ub1024|2048  a larger physical batch for prompt processing
#
# The prefill modifiers exist because prompt processing is where the time actually
# goes: 45% and then 63% of the time inside the model on two measured benchmark
# cases, producing no tokens at all. Every earlier experiment here tuned decode,
# which is the smaller half.
#
# "base" means no modifiers. "mtp3-nopreserve" against "mtp3" isolates reasoning
# preserve; plain "nopreserve" against "mtp3" would also drop speculative decoding,
# which is why the old flat names could not be compared. Order does not matter: the
# name is canonicalised (model, speculation, thinking) so one configuration is always
# one results column (e.g. "local-qwen3.8-27b--mtp3-nopreserve").
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODELS="${MODELS:-$HOME/models}"
UNIT=/etc/systemd/system/llama-server.service
STATE="${LLAMA_PROFILE_FILE:-$HOME/.llama-profile}"
HOST="${LLAMA_HOST:-172.18.0.1}"
PORT="${LLAMA_PORT:-8090}"

MODEL_DEFAULT="$MODELS/Qwen3.8-27B-UD-Q4_K_M.gguf"
MTP_DRAFT="$MODELS/mtp-Qwen3.8-27B-Q4_0.gguf"

MODIFIERS="q6 moe mtp2 mtp3 mtp5 ngram nopreserve cachereuse ctx32k ctx64k ub1024 ub2048"
EXAMPLES="base mtp3 mtp5 mtp3-ngram mtp3-nopreserve mtp3-cachereuse mtp3-ctx32k mtp3-ub2048 q6-mtp3 moe"
CACHE_REUSE_CHUNK="${CACHE_REUSE_CHUNK:-256}"

# Flags shared by every profile: all layers on the GPU, one slot (runs are serial),
# an 8-bit KV cache, and Qwen's own sampling defaults. The context size is passed in
# because a modifier can change it, and it keeps its place in the line so a profile
# that does not touch it renders exactly as before.
common() {
  echo "-ngl 99 -c ${1:-131072} -np 1 --cache-type-k q8_0 --cache-type-v q8_0 --top-p 0.95 --top-k 20 --jinja --metrics"
}

# Read a profile name into P_MODEL, P_FLAGS, P_ALIAS and the canonical P_NAME.
# Fails on an unknown modifier, two of a kind, or a pairing we have no files for.
parse_profile() {
  local name="$1" part model="" mtp="" ngram="" nopreserve="" cachereuse="" ctx="" ub=""
  for part in ${name//-/ }; do
    case "$part" in
      base) ;;
      q6 | moe)
        [ -z "$model" ] || { echo "two model modifiers in '$name'" >&2; return 1; }
        model="$part" ;;
      mtp2 | mtp3 | mtp5)
        [ -z "$mtp" ] || { echo "two MTP modifiers in '$name'" >&2; return 1; }
        mtp="${part#mtp}" ;;
      ngram) ngram=1 ;;
      nopreserve) nopreserve=1 ;;
      cachereuse) cachereuse=1 ;;
      ctx32k) ctx=32768 ;;
      ctx64k) ctx=65536 ;;
      ub1024) ub=1024 ;;
      ub2048) ub=2048 ;;
      *) echo "unknown modifier '$part' in '$name' (have: base $MODIFIERS)" >&2; return 1 ;;
    esac
  done

  case "$model" in
    q6) P_MODEL="$MODELS/Qwen3.8-27B-UD-Q6_K.gguf"; P_ALIAS=local-qwen3.8-27b ;;
    moe) P_MODEL="$MODELS/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"; P_ALIAS=local-qwen3.6-35b-a3b ;;
    *) P_MODEL="$MODEL_DEFAULT"; P_ALIAS=local-qwen3.8-27b ;;
  esac

  # The draft head is Qwen3.8-27B's own, so it follows that model through a
  # requantisation but has no counterpart for the MoE.
  if [ -n "$mtp" ] && [ "$model" = moe ]; then
    echo "no MTP draft head for the MoE; drop mtp from '$name'" >&2
    return 1
  fi

  local flags=() spec=()
  if [ -n "$mtp" ]; then
    flags+=(--model-draft "$MTP_DRAFT" -ngld 99)
    spec+=(draft-mtp)
  fi
  [ -n "$ngram" ] && spec+=(ngram-mod)
  if [ ${#spec[@]} -gt 0 ]; then
    flags+=(--spec-type "$(IFS=,; echo "${spec[*]}")")
  fi
  [ -n "$mtp" ] && flags+=(--spec-draft-n-max "$mtp")
  [ -n "$nopreserve" ] && flags+=(--no-reasoning-preserve)
  [ -n "$cachereuse" ] && flags+=(--cache-reuse "$CACHE_REUSE_CHUNK")
  [ -n "$ub" ] && flags+=(-ub "$ub")
  P_FLAGS="${flags[*]:-}"
  P_CTX="$ctx"

  local parts=()
  [ -n "$model" ] && parts+=("$model")
  [ -n "$mtp" ] && parts+=("mtp$mtp")
  [ -n "$ngram" ] && parts+=(ngram)
  [ -n "$nopreserve" ] && parts+=(nopreserve)
  [ -n "$cachereuse" ] && parts+=(cachereuse)
  [ "$ctx" = 32768 ] && parts+=(ctx32k)
  [ "$ctx" = 65536 ] && parts+=(ctx64k)
  [ -n "$ub" ] && parts+=("ub$ub")
  if [ ${#parts[@]} -eq 0 ]; then
    P_NAME=base
  else
    P_NAME="$(IFS=-; echo "${parts[*]}")"
  fi
}

write_unit() {
  [ -f "$P_MODEL" ] || { echo "no model file: $P_MODEL" >&2; return 1; }
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=llama.cpp server (profile: $P_NAME)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$USER
Group=$USER
SupplementaryGroups=render video
ExecStart=$HOME/llama.cpp/build/bin/llama-server -m $P_MODEL $(common "$P_CTX") $P_FLAGS --host $HOST --port $PORT -a $P_ALIAS
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

case "${1:-list}" in
  list)
    echo "modifiers: base $MODIFIERS"
    echo "examples:  $EXAMPLES"
    echo "running:   $(cat "$STATE" 2>/dev/null || echo unknown)"
    grep -o 'llama-server .*' "$UNIT" 2>/dev/null | cut -c1-200 || true
    ;;
  label) cat "$STATE" 2>/dev/null || echo unknown ;;
  describe)
    # What the server is ACTUALLY running, as JSON, for a benchmark result to record.
    # Read from the unit and the state file - never from a name passed in - so the
    # recorded value is an observation rather than a claim. A result that carries the
    # whole ExecStart line still means something after a profile is redefined.
    name=$(cat "$STATE" 2>/dev/null || echo unknown)
    exec_line=$(grep -m1 '^ExecStart=' "$UNIT" 2>/dev/null | sed 's/^ExecStart=//')
    active=$(systemctl is-active llama-server 2>/dev/null || true)
    # WHICH llama.cpp built the running server, not just how it was invoked. The
    # kernels that decide performance - the RDNA patches, the speculative-decoding
    # paths - live in the shared libraries, not in the small launcher, so a hash of
    # the binary would say nothing. The source is a git checkout, so identify it by
    # commit, branch and whether the tree was dirty: a patched build (git am onto a
    # branch) is then visibly a different thing from stock. Nothing is executed here,
    # so this is safe to call while a case is running.
    bin=${exec_line%% *}
    src=$(cd "$(dirname "$bin")/../.." 2>/dev/null && pwd || echo "")
    commit=$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)
    branch=$(git -C "$src" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
    dirty=false
    [ -n "$(git -C "$src" status --porcelain --untracked-files=no 2>/dev/null)" ] && dirty=true
    # The newest artifact in the build directory. A source tree that moved on without
    # being rebuilt cannot then pass as the build that actually ran.
    newest=$(find "$(dirname "$bin")" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    built=""
    [ -n "$newest" ] && built=$(date -u -d "@${newest%.*}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    PROFILE="$name" EXEC="$exec_line" ACTIVE="$active" SRC="$src" COMMIT="$commit" \
    BRANCH="$branch" DIRTY="$dirty" BUILT="$built" python3 -c 'import json,os
e=os.environ
print(json.dumps({"profile":e["PROFILE"],"execStart":e["EXEC"],"active":e["ACTIVE"],
  "build":{"source":e["SRC"],"commit":e["COMMIT"],"branch":e["BRANCH"],
           "dirty":e["DIRTY"]=="true","builtAt":e["BUILT"] or None}}))'
    ;;
  flags)
    parse_profile "${2:?which profile}"
    echo "$P_NAME: -m $P_MODEL $(common "$P_CTX") $P_FLAGS -a $P_ALIAS"
    ;;
  set)
    parse_profile "${2:?which profile}"
    write_unit
    sudo systemctl daemon-reload
    sudo systemctl restart llama-server
    echo "$P_NAME" > "$STATE"
    for _ in $(seq 1 120); do
      curl -fs "http://$HOST:$PORT/health" >/dev/null 2>&1 && { echo "llama-server up on profile $P_NAME"; exit 0; }
      sleep 5
    done
    echo "llama-server did not become healthy; check: journalctl -u llama-server -n 40" >&2
    exit 1
    ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
