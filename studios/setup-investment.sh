#!/usr/bin/env bash
# One-time setup for the Benchmark Agent Studio on the box. Run from ~/agent-studio.
#   scripts/benchmark-studio/setup.sh
# Creates the benchmark_studio database and its own Mongo user, and writes
# benchmark.env with fresh random secrets. It does NOT ask for or write the
# Alpaca or Tavily keys: open benchmark.env yourself and fill those in.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
cd "$ENV_DIR"
ENV_FILE=benchmark.env
PROD_ENV=docker-compose.nuc.env
[ -f "$ENV_FILE" ] && { echo "$ENV_FILE already exists; leaving it alone."; exit 0; }

ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
DB_PW=$(openssl rand -hex 24)
docker exec "$MONGO_CONTAINER" mongosh --quiet "mongodb://root:${ROOT_PW}@localhost:27017/?authSource=admin" --eval "
  const d = db.getSiblingDB('benchmark_studio');
  if (!d.getUser('benchmark')) d.createUser({ user: 'benchmark', pwd: '${DB_PW}', roles: [{ role: 'dbOwner', db: 'benchmark_studio' }] });
  else d.updateUser('benchmark', { pwd: '${DB_PW}' });
" >/dev/null

envval() { grep "^$1=" "$PROD_ENV" | head -1 | cut -d= -f2-; }
mkdir -p benchmark-state
{
  echo "BENCHMARK_HOST=server.example.ts.net"
  echo "BENCHMARK_MODEL=claude-sonnet-5"
  echo "BENCHMARK_DB_PASSWORD=$DB_PW"
  echo "SECRETS_ENCRYPTION_KEY=$(openssl rand -base64 32)"
  echo "MCP_INTERNAL_API_KEY=$(openssl rand -hex 24)"
  echo "PANEL_TOKEN_SECRET=$(openssl rand -hex 32)"
  echo "NEXTAUTH_SECRET=$(openssl rand -base64 32)"
  echo "ANTHROPIC_API_KEY=$(envval ANTHROPIC_API_KEY)"
  echo "OPENAI_API_KEY=$(envval OPENAI_API_KEY)"
  echo ""
  echo "# Fill these in yourself (paper trading keys and a Tavily key). Never paste them into a chat."
  echo "ALPACA_API_KEY="
  echo "ALPACA_SECRET_KEY="
  echo "TAVILY_API_KEY="
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE (mode 600). Now add ALPACA_API_KEY, ALPACA_SECRET_KEY and TAVILY_API_KEY."
