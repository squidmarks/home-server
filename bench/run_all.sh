#!/usr/bin/env bash
# Run every case on several models in sequence, sharing one run id.
#   BENCH_RUN_ID=myrun ./run_all.sh claude-sonnet-5 claude-haiku-4-5 local-qwen3-32b
cd "$(dirname "$0")"
export BENCH_RUN_ID="${BENCH_RUN_ID:-full-$(date +%m%d-%H%M)}"
for m in "$@"; do
  echo ">>> model: $m"
  ./bench.sh run "$m" < /dev/null || echo "!!! $m finished with problems (see above)"
done
echo "ALL DONE $BENCH_RUN_ID"
