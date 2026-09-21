#!/usr/bin/env bash
# The local model server (llama.cpp) as a set of named profiles, so a benchmark run
# can say which one produced it and switching between them is one command.
#
#   ./profiles.sh list             what is defined, and what is running now
#   ./profiles.sh set mtp3         write the unit, restart, wait for the model to load
#   ./profiles.sh label            print the running profile's name (for BENCH server setup)
#
# Adding a profile: give it a name and the flags after the model. Keep the name
# short; it becomes part of a results column (e.g. "local-qwen3.8-27b--mtp3").
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODELS="${MODELS:-$HOME/models}"
UNIT=/etc/systemd/system/llama-server.service
STATE="${LLAMA_PROFILE_FILE:-$HOME/.llama-profile}"
HOST="${LLAMA_HOST:-172.18.0.1}"
PORT="${LLAMA_PORT:-8090}"

MODEL_DEFAULT="$MODELS/Qwen3.8-27B-UD-Q4_K_M.gguf"
MTP_DRAFT="$MODELS/mtp-Qwen3.8-27B-Q4_0.gguf"

# Flags shared by every profile: all layers on the GPU, one slot (runs are serial),
# 128K context with an 8-bit KV cache, and Qwen's own sampling defaults.
common() {
  echo "-ngl 99 -c 131072 -np 1 --cache-type-k q8_0 --cache-type-v q8_0 --top-p 0.95 --top-k 20 --jinja --metrics"
}

# name -> model file and the flags that make this profile different.
profile_model() {
  case "$1" in
    q6) echo "$MODELS/Qwen3.8-27B-UD-Q6_K.gguf" ;;
    moe*) echo "$MODELS/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" ;;
    *) echo "$MODEL_DEFAULT" ;;
  esac
}
profile_flags() {
  case "$1" in
    base|q6|moe) echo "" ;;
    mtp2|mtp3|mtp5|moe-mtp3) echo "--model-draft $MTP_DRAFT -ngld 99 --spec-type draft-mtp --spec-draft-n-max ${1##*mtp}" ;;
    ngram) echo "--spec-type ngram-mod" ;;
    mtp3-ngram) echo "--model-draft $MTP_DRAFT -ngld 99 --spec-type draft-mtp,ngram-mod --spec-draft-n-max 3" ;;
    nopreserve) echo "--no-reasoning-preserve" ;;
    *) return 1 ;;
  esac
}
PROFILES="base mtp2 mtp3 mtp5 mtp3-ngram ngram nopreserve q6 moe"

alias_of() { case "$1" in moe*) echo "local-qwen3.6-35b-a3b" ;; *) echo "local-qwen3.8-27b" ;; esac; }

write_unit() {
  local name="$1" model flags
  model=$(profile_model "$name"); flags=$(profile_flags "$name")
  [ -f "$model" ] || { echo "no model file: $model" >&2; return 1; }
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=llama.cpp server (profile: $name)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$USER
Group=$USER
SupplementaryGroups=render video
ExecStart=$HOME/llama.cpp/build/bin/llama-server -m $model $(common) $flags --host $HOST --port $PORT -a $(alias_of "$name")
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

case "${1:-list}" in
  list)
    echo "profiles: $PROFILES"
    echo "running:  $(cat "$STATE" 2>/dev/null || echo unknown)"
    grep -o 'llama-server .*' "$UNIT" 2>/dev/null | cut -c1-200 || true
    ;;
  label) cat "$STATE" 2>/dev/null || echo unknown ;;
  set)
    name="${2:?which profile}"
    profile_flags "$name" >/dev/null || { echo "unknown profile: $name (have: $PROFILES)" >&2; exit 1; }
    write_unit "$name"
    sudo systemctl daemon-reload
    sudo systemctl restart llama-server
    echo "$name" > "$STATE"
    for _ in $(seq 1 120); do
      curl -fs "http://$HOST:$PORT/health" >/dev/null 2>&1 && { echo "llama-server up on profile $name"; exit 0; }
      sleep 5
    done
    echo "llama-server did not become healthy; check: journalctl -u llama-server -n 40" >&2
    exit 1
    ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
