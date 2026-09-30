#!/usr/bin/env bash
# One-time setup for the shared agent-service on the home box. Run on the box:
#   ANTHROPIC_API_KEY=... OPENAI_API_KEY=... HA_TOKEN=... ~/infra/studios/setup-home.sh
# Creates the agent_studio platform database and its Mongo user, and writes
# studios.env (mode 600) with fresh random secrets plus the keys passed in the
# environment. Pipe the keys in from their source files; never paste them into
# a chat. Leaves an existing studios.env alone. Engine-specific settings for
# studios added later (Witness, Investment) are appended to the same file.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
cd "$ENV_DIR"
ENV_FILE=studios.env
[ -f "$ENV_FILE" ] && { echo "$ENV_FILE already exists; leaving it alone."; exit 0; }

ROOT_PW=$(grep '^MONGO_ROOT_PASSWORD=' "$MONGO_ENV" | cut -d= -f2)
DB_PW=$(openssl rand -hex 24)
docker exec "$MONGO_CONTAINER" mongosh --quiet "mongodb://root:${ROOT_PW}@localhost:27017/?authSource=admin" --eval "
  const d = db.getSiblingDB('agent_studio');
  if (!d.getUser('agent_studio')) d.createUser({ user: 'agent_studio', pwd: '${DB_PW}', roles: [{ role: 'dbOwner', db: 'agent_studio' }] });
  else d.updateUser('agent_studio', { pwd: '${DB_PW}' });
" >/dev/null

{
  echo "STUDIOS_HOST=${STUDIOS_HOST:-$(hostname).example.ts.net}"
  echo "STUDIOS_TAILNET_IP=$(tailscale ip -4)"
  echo "DEFAULT_MODEL=${DEFAULT_MODEL:-claude-sonnet-5}"
  echo "STUDIOS_DB_PASSWORD=$DB_PW"
  echo "SECRETS_ENCRYPTION_KEY=$(openssl rand -base64 32)"
  echo "MCP_INTERNAL_API_KEY=$(openssl rand -hex 24)"
  echo "PANEL_TOKEN_SECRET=$(openssl rand -hex 32)"
  echo "NEXTAUTH_SECRET=$(openssl rand -base64 32)"
  echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
  echo "OPENAI_API_KEY=${OPENAI_API_KEY:-}"
  echo ""
  echo "# Home Studio"
  echo "HOME_ADMIN_EMAILS=${HOME_ADMIN_EMAILS:-}"
  echo "HA_BASE_URL=${HA_BASE_URL:-http://<home-assistant-ip>}"
  echo "HA_TOKEN=${HA_TOKEN:-}"
  echo "HA_READONLY_ENTITIES=${HA_READONLY_ENTITIES:-}"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE (mode 600)."
