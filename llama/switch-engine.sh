#!/usr/bin/env bash
# Put the GPU under one engine or the other. One card, ~32 GiB: they cannot both
# hold a 16-19 GiB model, so switching is always stop-then-start.
#
#   ./switch-engine.sh qwen-vllm    Qwen3.8 MXFP4 on vLLM  (8080)
#   ./switch-engine.sh gemma-vllm   Gemma 4 26B A4B on vLLM (8080)
#   ./switch-engine.sh qwen-llama   Qwen3.8 Q4_K_M on llama.cpp (8090)
#   ./switch-engine.sh coder-strata Qwen3.8-Flash-Next Coder IQ1_M on Strata (8092)
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

# Every vLLM container: the MXFP4 launcher names its own, serve-model.sh names
# another, serve-sly.sh a third, and only one of them can have the card.
# Stopping "the" vLLM by a single name left another holding ~17 GiB and the next
# start died deep in engine init with a traceback that named nothing. vllm-sly
# also carries --restart unless-stopped, so `docker stop` is what removes it
# from contention; leaving it out here would put two engines on one card.
stop_vllm() {
  for n in "$VLLM_NAME" vllm-generic vllm-sly; do
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
stop_strata() {
  pgrep -f "serve/server.py --engine strata" >/dev/null && { echo ">>> stopping strata"; "$HERE/serve-strata.sh" stop; }
  return 0
}
stop_llama() {
  if systemctl is-active --quiet llama-server; then echo ">>> stopping llama-server"; sudo systemctl stop llama-server; fi
}

case "$TARGET" in
  gemma-vllm)
    stop_strata
    stop_llama
    stop_vllm
    exec "$HERE/serve-model.sh" gemma
    ;;
  qwen-llama|llama)
    stop_strata
    stop_vllm
    echo ">>> starting llama.cpp on profile $PROFILE"
    "$HERE/profiles.sh" set "$PROFILE" || exit 3
    ;;
  qwen-vllm)
    # sly-radiance, the primary engine since 2026-09-30: 262K context against
    # the radiance tree's 65K, the same ~72 tok/s decode, a better mean score,
    # a pullable image, and image input. This branch used to run
    # `vllm-profiles.sh set short-dflash`, which meant the shim loading this
    # model id by name would tear sly down and bring up the superseded 65K
    # build -- silently losing three quarters of the context window and vision.
    stop_strata
    stop_llama
    stop_vllm
    exec "$HERE/serve-sly.sh"
    ;;
  qwen-vllm-radiance)
    # The superseded radiance tree, kept reachable to reproduce results recorded
    # against it. short-dflash is the shape the sweeps settled on; the bare
    # `vllm` branch below comes up in the launcher's untuned default instead.
    stop_strata
    stop_llama
    stop_vllm
    exec "$HERE/vllm-profiles.sh" set short-dflash
    ;;
  vllm)
    stop_strata
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
  coder-strata)
    stop_llama
    stop_vllm
    exec "$HERE/serve-strata.sh"
    ;;
  *) echo "usage: $0 qwen-vllm|qwen-vllm-radiance|gemma-vllm|qwen-llama|coder-strata (or llama|vllm)" >&2; exit 2 ;;
esac
