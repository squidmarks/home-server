#!/usr/bin/env bash
# Choose the model the Benchmark Studio's development router (and any agent with
# no model of its own) runs on, then restart the agent-service.
#   scripts/benchmark-studio/set-model.sh claude-haiku-4-5
#   scripts/benchmark-studio/set-model.sh local-qwen3-32b
# Any id the agent-service knows works (claude-*, gpt-*, local-*).
set -euo pipefail
. "$(dirname "$0")/../env.sh"
cd "$ENV_DIR"
model="${1:?usage: set-model.sh <model-id>}"
[[ "$model" =~ ^[a-z0-9][a-z0-9._-]+$ ]] || { echo "not a valid model id: $model" >&2; exit 1; }
if grep -q '^BENCHMARK_MODEL=' benchmark.env; then
  sed -i "s|^BENCHMARK_MODEL=.*|BENCHMARK_MODEL=$model|" benchmark.env
else
  echo "BENCHMARK_MODEL=$model" >> benchmark.env
fi
docker compose -p benchmark-studio -f "$STUDIOS_DIR/investment.yml" --env-file benchmark.env up -d agent-service >/dev/null
for _ in $(seq 1 40); do curl -fs http://127.0.0.1:3501/health >/dev/null 2>&1 && { echo "benchmark studio router model is now: $model"; exit 0; }; sleep 3; done
echo "agent-service did not come back healthy" >&2; exit 1
