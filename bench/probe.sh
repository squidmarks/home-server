#!/usr/bin/env bash
# A few-minute look at how the local model server behaves under different thinking
# settings, without running a whole case: one realistic first turn, each setting a
# few times, one table of wall time, prefill, decode rate and how much it thought.
#   ./probe.sh <model-alias> <variants> [repeats]
#   ./probe.sh local-qwen3.8-27b default,effort=low,off 2
# Variants: "default" (server default), "off" (no thinking), "effort=<level>".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
docker run --rm --name bench-probe --network host \
  -v "$AGENT_STUDIO_DIR":/w -w /w \
  -e LOCAL_LLM_BASE_URL="${LOCAL_LLM_BASE_URL:-http://172.18.0.1:8090/v1}" \
  -e GUIDANCE_DIR=/w/profiles/benchmark/engine/src/context \
  node:22-slim node scripts/bench/probe-local.mjs \
  --model "${1:?model alias}" --variants "${2:?variants}" --repeats "${3:-1}" \
  --case "${BENCH_PROBE_CASE:-inv-news-trader}"
