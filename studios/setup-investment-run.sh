#!/usr/bin/env bash
# One-time setup for the development benchmark's throwaway studio instance.
# Run from ~/agent-studio on the box:  scripts/benchmark-studio/setup-run.sh
# Creates a Mongo user for the benchmark_run database and writes benchmark-run.env,
# copying the API keys from benchmark.env on this machine (they are never printed).
set -euo pipefail
. "$(dirname "$0")/../env.sh"
cd "$ENV_DIR"
ENV_FILE=benchmark-run.env
SRC=benchmark.env
[ -f "$ENV_FILE" ] && { echo "$ENV_FILE already exists; leaving it alone."; exit 0; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
DB_PW=$(openssl rand -hex 24)
docker exec "$MONGO_CONTAINER" mongosh --quiet "mongodb://root:${ROOT_PW}@localhost:27017/?authSource=admin" --eval "
  const a = db.getSiblingDB('admin');
  if (!a.getUser('benchmark_run')) a.createUser({ user: 'benchmark_run', pwd: '${DB_PW}', roles: [{ role: 'readWrite', db: 'benchmark_run' }] });
  else a.updateUser('benchmark_run', { pwd: '${DB_PW}' });
" >/dev/null

val() { grep "^$1=" "$SRC" | head -1 | cut -d= -f2-; }
mkdir -p benchmark-run-state
{
  echo "BENCH_MODEL=claude-sonnet-5"
  echo "BENCHMARK_RUN_DB_PASSWORD=$DB_PW"
  echo "SECRETS_ENCRYPTION_KEY=$(openssl rand -base64 32)"
  echo "MCP_INTERNAL_API_KEY=$(openssl rand -hex 24)"
  echo "PANEL_TOKEN_SECRET=$(openssl rand -hex 32)"
  for k in ANTHROPIC_API_KEY OPENAI_API_KEY ALPACA_API_KEY ALPACA_SECRET_KEY TAVILY_API_KEY; do echo "$k=$(val $k)"; done
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE (mode 600)"
