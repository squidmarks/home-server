#!/usr/bin/env bash
# Run the development cases on several router models in sequence, sharing one run id.
#   BENCH_SIM_MODEL=claude-haiku-4-5 BENCH_JUDGE_MODEL=claude-sonnet-5 \
#     ./run_dev_all.sh claude-sonnet-5 claude-haiku-4-5
cd "$(dirname "$0")"
export BENCH_RUN_ID="${BENCH_RUN_ID:-dev-$(date +%m%d-%H%M)}"
for m in "$@"; do
  echo ">>> router model: $m"
  ./bench-dev.sh run "$m" < /dev/null || echo "!!! $m finished with problems (see above)"
done
echo "ALL DONE $BENCH_RUN_ID"
