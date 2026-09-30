#!/usr/bin/env bash
# Qwen3.8-27B on vLLM, via SlyBase's prebuilt sly-radiance image. The primary
# engine on this box since 2026-09-30.
#
#   ./serve-sly.sh            start it (idempotent: replaces a running one)
#   ./serve-sly.sh stop       stop and remove it
#   ./serve-sly.sh describe   JSON for a benchmark result to record
#
# Why this image rather than the radiance tree in ~/radiance-vllm-mxfp4: it is a
# versioned pull with its own ROCm 10 userspace, so it does not depend on the
# host's ROCm (Ubuntu's 7.1.x) and does not apply Python patches at build time.
# Measured on the investment suite the same day, at the same reasoning effort:
#
#   sly           262K ctx   264 s median   0.981 mean score   72 tok/s decode
#   radiance 0.9.3 65K ctx   193 s median   0.882 (one run built no agent)
#   llama.cpp     262K ctx   350 s median   1.000              40 tok/s decode
#
# The published 133 tok/s is a BetterBench category-weighted figure; generic
# novel generation measures 59-63, and agentic turns 72.
set -euo pipefail

IMAGE="${SLY_IMAGE:-ghcr.io/slybase/vllm-sly-radiance:0.4.0-rocm10.0}"
NAME="${SLY_CONTAINER:-vllm-sly}"
PORT="${SLY_PORT:-8080}"
MODELS="${MODELS:-$HOME/models}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
# The weights sly is built around, and its drafter. Not the same files as the
# radiance tree used: that served Qwen3.8-27B-MXFP4-mtpfp8 with an FP8 drafter.
MODEL_REPO="${SLY_MODEL:-amd/Qwen3.8-27B-Quark-AWQ-MXFP4}"
DRAFTER="${SLY_DRAFTER:-/models/Qwen3.8-27B-DFlash2-W4A16}"
MAXLEN="${SLY_MAXLEN:-262144}"

# Docker wants numeric GIDs; --group-add by name fails on this host because the
# container's own group file has neither.
gid() { getent group "$1" | cut -d: -f3; }

stop_sly() {
  docker ps -aq --filter "name=^${NAME}$" | grep -q . || return 0
  echo ">>> stopping $NAME"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # docker returns before the card is free.
  for _ in $(seq 1 30); do
    used=$(rocm-smi --showmemuse 2>/dev/null | grep -oE "VRAM%\): [0-9]+" | grep -oE "[0-9]+$" | head -1)
    [ -z "$used" ] || [ "$used" -lt 10 ] && break
    sleep 2
  done
}

# Any env var that changes the compiled graph -- RADIANCE_FAST_DRAFT, the
# multimodal limits, the speculative config -- invalidates these. Reusing them
# after such a change kills startup about ninety seconds AFTER a successful
# model load, with a "Cubin file saved by TritonBundler not found" buried in a
# torch traceback that names nothing about caches. Clear them when you change
# one of those, not when you change a sampling default.
drop_caches() {
  for v in vllm-sly-cache triton-sly-cache aiter-sly-cache; do
    docker volume rm "$v" >/dev/null 2>&1 || true
  done
  echo ">>> compile caches cleared; expect a ~10 minute first start"
}

case "${1:-start}" in
  stop) stop_sly; exit 0 ;;
  drop-caches) drop_caches; exit 0 ;;
  describe)
    docker inspect "$NAME" >/dev/null 2>&1 || { echo '{}'; exit 0; }
    printf '{"engine":"vllm-sly","image":"%s","model":"%s","maxlen":%s}\n' \
      "$(docker inspect "$NAME" --format '{{.Config.Image}}')" "$MODEL_REPO" "$MAXLEN"
    exit 0 ;;
esac

stop_sly
echo ">>> starting $NAME ($IMAGE)"
# --restart unless-stopped: this is the primary engine, so it comes back after a
# reboot. llama-server's unit is disabled for the same reason -- two engines
# racing for one card on boot is a confusing way to lose an afternoon.
#
# --limit-mm-per-prompt.image 1: sly's published command sets 0, which disables
# image input entirely and answers attachments with "At most 0 image(s) may be
# provided". The model has a vision tower and reads images correctly. The cost
# is real but narrow: the dflash drafter cannot handle multimodal embeddings, so
# an image request loses speculation and runs about 28% slower (57.9 vs 80.5
# tok/s measured). Text-only requests are untouched. --skip-mm-profiling is
# deliberately NOT set alongside it: with images enabled that would leave the
# vision encoder's VRAM unreserved and OOM mid-request rather than at startup.
# The encoder costs ~2 GiB of KV pool (12.21 -> 10.16 GiB), which still holds
# 300k tokens against a 262k request.
docker run -d --name "$NAME" --restart unless-stopped \
  --device=/dev/kfd --device=/dev/dri \
  --group-add "$(gid video)" --group-add "$(gid render)" \
  --security-opt seccomp=unconfined --ipc=host -p "${PORT}:8000" \
  -v "$HF_CACHE:/root/.cache/huggingface" \
  -v "$MODELS:/models" \
  -v vllm-sly-cache:/root/.cache/vllm -v triton-sly-cache:/root/.triton -v aiter-sly-cache:/root/.aiter \
  -e HIP_VISIBLE_DEVICES=0 -e GPU_MAX_HW_QUEUES=2 \
  -e RADIANCE_MXFP4=1 -e RADIANCE_MXFP4_W4A8=1 -e RADIANCE_MXFP4_W4A8_MIN_M=0 \
  -e RADIANCE_MXFP4_DECODE_MAX_M=128 -e RADIANCE_MXFP4_A_TILED_MIN_M=513 \
  -e RADIANCE_MXFP4_WPERM=1 -e RADIANCE_LMHEAD_INT4=1 \
  -e RADIANCE_FUSED_NORM_QUANT=1 -e RADIANCE_KV_GROUP_SIZE=8 \
  -e RADIANCE_EMBED_INT8=1 -e RADIANCE_EMBED_BITS=4 \
  "$IMAGE" \
  --model "$MODEL_REPO" --quantization quark \
  --served-model-name local-qwen3.8-27b-mxfp4 Qwen3.8 "$MODEL_REPO" \
  --max-model-len "$MAXLEN" --gpu-memory-utilization 0.96 \
  --kv-cache-dtype fp8 --mamba-ssm-cache-dtype bfloat16 \
  --speculative-config.method dflash \
  --speculative-config.model "$DRAFTER" \
  --speculative-config.num_speculative_tokens 7 \
  --speculative-config.draft_sample_method probabilistic \
  --speculative-config.attention_backend TRITON_ATTN \
  --attention-backend ROCM_AITER_UNIFIED_ATTN \
  --max-num-seqs 8 --max-num-batched-tokens 2048 \
  --compilation-config.cudagraph_mode FULL_AND_PIECEWISE \
  --compilation-config.cudagraph_capture_sizes '[8,16,24,32,40,48,56,64]' \
  --enable-prefix-caching \
  --limit-mm-per-prompt.image 1 --limit-mm-per-prompt.video 0 \
  --enable-auto-tool-choice --tool-call-parser qwen3_xml \
  --reasoning-parser qwen3 --chat-template /opt/qwen-fixed.jinja \
  --default-chat-template-kwargs '{"reasoning_effort": "medium"}' \
  --override-generation-config '{"temperature": 1.0, "top_p": 0.95, "top_k": 20}' >/dev/null

echo ">>> waiting for $NAME to serve (first start compiles kernels, ~10 min)"
for i in $(seq 1 120); do
  if curl -fs --max-time 4 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
    echo ">>> serving after $((i*10))s"
    exit 0
  fi
  docker ps -q --filter "name=^${NAME}$" | grep -q . || {
    echo "!! $NAME exited:"; docker logs "$NAME" 2>&1 | tail -25; exit 1; }
  sleep 10
done
echo "!! $NAME did not serve in 20 minutes"; docker logs "$NAME" 2>&1 | tail -25; exit 1
