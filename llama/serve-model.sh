#!/usr/bin/env bash
# Serve a model that is NOT Qwen3.8-MXFP4 on vLLM.
#
# radiance-vllm-mxfp4/serve-mxfp4.sh is not a general launcher: it pins MXFP4,
# the libr4d GDN kernels and an fp16 SSM cache, all of which exist for Qwen3.8's
# hybrid Gated DeltaNet and mean nothing to an ordinary transformer. Rather than
# add a second personality to a 900-line script, this is the plain path: the
# same image and the same device plumbing, with flags that came from the model.
#
#   ./serve-model.sh gemma     start Gemma 4 26B A4B on :8080
#   ./serve-model.sh stop      stop whatever this script started
set -uo pipefail
IMAGE="${IMAGE:-stilldeadcode/vllm-radiance:0.9.3}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
PORT="${PORT:-8080}"
NAME="vllm-generic"

# Numeric GIDs: `--group-add keep-groups` is podman-only, docker wants numbers.
GROUPS_FLAGS=()
for g in render video; do
  gid=$(getent group "$g" | cut -d: -f3)
  [ -n "$gid" ] && GROUPS_FLAGS+=(--group-add "$gid")
done

model_args() {
  case "$1" in
    gemma)
      # INT4 (compressed-tensors) over Google's QAT weights, so 4-bit is trained
      # for rather than imposed afterwards. 17.2 GiB of weights on a 31.9 GiB
      # card leaves real room for KV at 64K -- the FP8 build does not (28.6 GiB
      # of weights leaves about three).
      echo "--model /models/gemma-4-26B-A4B-AWQ-INT4 \
--served-model-name Gemma4 gemma-4-26b-a4b local-gemma-4-26b-a4b \
--max-model-len 65536 --max-num-seqs 8 --max-num-batched-tokens 4096 \
--gpu-memory-utilization 0.92 \
--tool-call-parser gemma4 --reasoning-parser gemma4 --enable-auto-tool-choice \
--override-generation-config {\"temperature\":0}"
      ;;
    *) return 1 ;;
  esac
}

case "${1:-}" in
  stop)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo ">>> stopped $NAME"
    ;;
  *)
    want="${1:?usage: $0 <model>|stop}"
    args=$(model_args "$want") || { echo "!! unknown model: $want" >&2; exit 2; }
    # What this model must report in /v1/models before the start counts.
    case "$want" in
      gemma) EXPECT_ID=local-gemma-4-26b-a4b ;;
      *)     echo "!! no expected served id for $want" >&2; exit 2 ;;
    esac
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo ">>> starting $want on :$PORT (first start compiles kernels; several minutes)"
    # shellcheck disable=SC2086
    docker run -d --name "$NAME" --privileged --ipc=host --network=host \
      --device /dev/kfd --device /dev/dri "${GROUPS_FLAGS[@]}" \
      --security-opt seccomp=unconfined --cap-add SYS_PTRACE --cap-add SYS_NICE \
      --shm-size 16g \
      -v "$HF_CACHE":/root/.cache/huggingface \
      -v "$MODELS_DIR":/models \
      "$IMAGE" $args --host 0.0.0.0 --port "$PORT" >/dev/null || exit 3
    echo ">>> container up; waiting for $want to serve on :$PORT"
    for _ in $(seq 1 120); do
      # Ask WHAT is serving, not merely whether something answers. A bare 200 on
      # this port was once the shim's own /health -- the launcher had inherited
      # the shim's PORT, nothing had started, and the switch reported success.
      served=$(curl -sf -m 5 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(",".join(m["id"] for m in json.load(sys.stdin).get("data",[])))
except Exception: print("")' 2>/dev/null)
      case ",$served," in
        *",$EXPECT_ID,"*) echo ">>> $want is serving ($served)"; exit 0 ;;
      esac
      if ! docker ps -q --filter "name=$NAME" | grep -q .; then
        echo "!! exited while starting; last lines:" >&2
        docker logs --tail 25 "$NAME" 2>&1 | tail -25 >&2
        exit 5
      fi
      sleep 10
    done
    echo "!! did not become healthy within 20 minutes" >&2; exit 4
    ;;
esac
