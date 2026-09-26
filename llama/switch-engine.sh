#!/usr/bin/env bash
# Put the GPU under one engine or the other. One card, ~32 GiB: they cannot both
# hold a 16-19 GiB model, so switching is always stop-then-start.
#
#   ./switch-engine.sh qwen-vllm    Qwen3.8 MXFP4 on vLLM  (8080)
#   ./switch-engine.sh gemma-vllm   Gemma 4 26B A4B on vLLM (8080)
#   ./switch-engine.sh qwen-llama   Qwen3.8 Q4_K_M on llama.cpp (8090)
#   ./switch-engine.sh llama|vllm   the old engine-only names, still accepted
#
# The argument is a KEY from a fixed set, never a path and never flags. The shim
# that calls this proxies request bodies from the studio, so the set of things
# it can ask for has to be closed here rather than assembled there.
#
# This is the ONLY privileged piece of the shim. The shim proxies request bodies
# from the studio, so it must not also hold the right to run arbitrary commands:
# it invokes this with one argument from a fixed set, and everything needing root
# lives here.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

TARGET="${1:-}"
PROFILE="${LLAMA_PROFILE:-mtp3-temp0}"
VLLM_DIR="${VLLM_DIR:-$HOME/radiance-vllm-mxfp4}"
VLLM_NAME="${VLLM_CONTAINER:-vllmmxfp4074}"

# Both vLLM containers: the MXFP4 launcher names its own, serve-model.sh names
# another, and only one of them can have the card. Stopping "the" vLLM by a
# single name left the other holding ~17 GiB and the next start died deep in
# engine init with a traceback that named nothing.
stop_vllm() {
  for n in "$VLLM_NAME" vllm-generic; do
    docker ps -q --filter "name=$n" | grep -q . && { echo ">>> stopping $n"; docker stop "$n" >/dev/null; }
  done
  # docker stop returns when the container is gone, not when the card is free.
  for _ in $(seq 1 30); do
    used=$(rocm-smi --showmemuse 2>/dev/null | grep -oE "VRAM%\): [0-9]+" | grep -oE "[0-9]+$" | head -1)
    [ -z "$used" ] && break
    [ "$used" -lt 5 ] && break
    sleep 2
  done
  return 0
}
stop_llama() {
  if systemctl is-active --quiet llama-server; then echo ">>> stopping llama-server"; sudo systemctl stop llama-server; fi
}

case "$TARGET" in
  gemma-vllm)
    stop_llama
    stop_vllm
    exec "$HERE/serve-model.sh" gemma
    ;;
  qwen-llama|llama)
    stop_vllm
    echo ">>> starting llama.cpp on profile $PROFILE"
    "$HERE/profiles.sh" set "$PROFILE" || exit 3
    ;;
  qwen-vllm)
    # Not the bare `vllm` branch: that calls serve-tp1.sh with no profile
    # environment, so it comes up in the launcher's DEFAULT single-GPU shape
    # (MAXSEQS 3, MAXLEN 220000, CHUNK 2560) -- the long-context one. The shape
    # the sweeps actually settled on is short-dflash (dflash, SPEC 7, MAXSEQS 8,
    # MAXLEN 65536, CHUNK 4096). Loading a model by name and silently getting an
    # untuned configuration is exactly the kind of unattributable result the
    # profile machinery exists to prevent.
    stop_llama
    stop_vllm
    exec "$HERE/vllm-profiles.sh" set short-dflash
    ;;
  vllm)
    stop_llama
    [ -x "$VLLM_DIR/serve-tp1.sh" ] || { echo "!! $VLLM_DIR/serve-tp1.sh not found"; exit 2; }
    echo ">>> starting vLLM (first start compiles kernels; several minutes)"
    # temperature 0 and our own model id, so a benchmark arm is comparable with
    # the llama.cpp one and the studio can address it by the name it knows.
    ( cd "$VLLM_DIR" && DETACH=1 ./serve-tp1.sh \
        --override-generation-config '{"temperature":0}' \
        --served-model-name Qwen3.8 Qwen3.6 Qwen3.8-MXFP4 local-qwen3.8-27b-mxfp4 ) || exit 3
    # Wait for it to answer rather than returning while it is still compiling:
    # the admin page reports "switching" until this returns.
    for _ in $(seq 1 120); do
      curl -sf -o /dev/null "http://127.0.0.1:8080/health" && { echo ">>> vLLM is serving"; exit 0; }
      sleep 10
    done
    echo "!! vLLM did not become healthy within 20 minutes"; exit 4
    ;;
  *) echo "usage: $0 qwen-vllm|gemma-vllm|qwen-llama (or llama|vllm)" >&2; exit 2 ;;
esac
