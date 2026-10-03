#!/usr/bin/env bash
# Qwen3.8-Flash-Next Coder (IQ1_M) on Strata, the MoE runner that keeps experts
# in system RAM and caches the hot ones in VRAM. Trialled 2026-10-02:
#
#   262K ctx   ~106 tok/s short, 57 at 222K   prefill ~1,100-1,500 tok/s
#   needle recall OK to 222K (and to 431K with yarn 2, at half the decode speed)
#
# It needs the whole card -- the expert cache sizes itself to what is free --
# so switch-engine.sh stops vLLM/llama.cpp first. A cold start is ~2 minutes
# (about 30 GB of experts read into RAM).
#
#   ./serve-strata.sh            start it (idempotent: replaces a running one)
#   ./serve-strata.sh stop       stop it
#   ./serve-strata.sh describe   JSON for a benchmark result to record
set -euo pipefail

DIR="${STRATA_DIR:-$HOME/strata}"
# The 262K config. strata-coder-iq1_m-512k.json (yarn 2) also exists; it halves
# decode speed, so it is not the default.
CONFIG="${STRATA_CONFIG:-$DIR/strata-coder-iq1_m.json}"
PORT="${STRATA_PORT:-8092}"
LOG="${STRATA_SERVE_LOG:-$DIR/serve.log}"
PATTERN="serve/server.py --engine strata"

stop() {
  pkill -f "$PATTERN" 2>/dev/null || true
  # The wrapper stops its engine child on SIGTERM; wait for both to be gone,
  # since the card is not free until the engine exits.
  for _ in $(seq 1 30); do
    pgrep -f "$PATTERN" >/dev/null || pgrep -f "^$DIR/engine/strata" >/dev/null || return 0
    sleep 2
  done
  pkill -9 -f "^$DIR/engine/strata" 2>/dev/null || true
  pkill -9 -f "$PATTERN" 2>/dev/null || true
}

case "${1:-start}" in
  stop)
    stop
    echo ">>> strata stopped"
    ;;
  describe)
    printf '{"engine":"strata","config":"%s","port":%s}\n' "$(basename "$CONFIG")" "$PORT"
    ;;
  start)
    stop
    [ -x "$DIR/.venv/bin/python" ] || { echo "!! $DIR/.venv not found (run setup.sh)"; exit 2; }
    echo ">>> starting strata ($(basename "$CONFIG")) on $PORT"
    # No --open: there is no browser here. Detached, so the switch script can
    # return once it answers -- and with EVERY descriptor redirected on the
    # subshell itself, not just on the server: the shim waits for this script's
    # stdout pipe to close, and a subshell left holding it kept a finished
    # switch "running" forever (2026-10-02). exec makes the subshell the server.
    (cd "$DIR" && exec setsid nohup .venv/bin/python serve/server.py --engine strata \
        --config "$CONFIG" --port "$PORT") >"$LOG" 2>&1 </dev/null &
    for _ in $(seq 1 60); do
      curl -sf -o /dev/null "http://127.0.0.1:$PORT/health" && { echo ">>> strata is serving"; exit 0; }
      pgrep -f "$PATTERN" >/dev/null || { echo "!! strata exited during start:"; tail -5 "$LOG"; exit 3; }
      sleep 10
    done
    echo "!! strata did not become healthy within 10 minutes"; exit 4
    ;;
  *) echo "usage: $0 [start|stop|describe]" >&2; exit 2 ;;
esac
