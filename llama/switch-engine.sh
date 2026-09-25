#!/usr/bin/env bash
# Put the GPU under one engine or the other. One card, ~32 GiB: they cannot both
# hold a 16-19 GiB model, so switching is always stop-then-start.
#
#   ./switch-engine.sh llama    llama.cpp on 8090, at the pinned profile
#   ./switch-engine.sh vllm     vLLM (radiance MXFP4) on 8080
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

stop_vllm() {
  docker ps -q --filter "name=$VLLM_NAME" | grep -q . && { echo ">>> stopping vLLM"; docker stop "$VLLM_NAME" >/dev/null; }
  return 0
}
stop_llama() {
  if systemctl is-active --quiet llama-server; then echo ">>> stopping llama-server"; sudo systemctl stop llama-server; fi
}

case "$TARGET" in
  llama)
    stop_vllm
    echo ">>> starting llama.cpp on profile $PROFILE"
    "$HERE/profiles.sh" set "$PROFILE" || exit 3
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
  *) echo "usage: $0 llama|vllm" >&2; exit 2 ;;
esac
