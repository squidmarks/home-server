#!/usr/bin/env bash
# Replace the Anthropic and OpenAI API keys in every env file on this machine that holds them.
#   ssh -t gpu '~/infra/studios/rotate-llm-keys.sh [--restart]'
#
# Run it in your own terminal: the keys are typed at a silent prompt, never passed as arguments,
# never printed, and never written anywhere except the env files. Each new key is checked against
# its provider first, and nothing is changed unless every key you entered is accepted.
# --restart also recreates the services that read the keys at startup (the workbench studio and
# the production Witness agent-service; a few seconds of downtime for each). Without it the
# script prints the commands. The benchmark's throwaway studio picks the keys up on its next case.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

restart=0; [ "${1:-}" = "--restart" ] && restart=1
files=$(grep -lE '^(ANTHROPIC|OPENAI)_API_KEY=' "$ENV_DIR"/*.env 2>/dev/null || true)
[ -n "$files" ] || { echo "no env files with LLM keys found in $ENV_DIR" >&2; exit 1; }
echo "These env files hold LLM keys and will be updated:"
echo "$files" | sed 's#^#  #'
echo

read -rsp "New Anthropic API key (blank to leave it alone): " ak; echo
read -rsp "New OpenAI API key (blank to leave it alone): " ok; echo
[ -n "$ak$ok" ] || { echo "nothing entered; no changes."; exit 0; }

# The key goes to curl on stdin as config, so it never appears in a process list.
check() { # provider key
  local code
  case "$1" in
    anthropic) code=$(printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$2" | curl -s -o /dev/null -w '%{http_code}' -K - https://api.anthropic.com/v1/models) ;;
    openai)    code=$(printf 'header = "Authorization: Bearer %s"\n' "$2" | curl -s -o /dev/null -w '%{http_code}' -K - https://api.openai.com/v1/models) ;;
  esac
  [ "$code" = "200" ] && echo "  $1: accepted" || { echo "  $1: NOT accepted (HTTP $code); nothing was changed" >&2; return 1; }
}
if [ -z "${SKIP_KEY_CHECK:-}" ]; then
  echo "Checking the keys with their providers..."
  [ -z "$ak" ] || check anthropic "$ak"
  [ -z "$ok" ] || check openai "$ok"
fi

for f in $files; do
  ANTHROPIC_NEW="$ak" OPENAI_NEW="$ok" python3 - "$f" <<'PY'
import os, sys, tempfile
path = sys.argv[1]
new = {"ANTHROPIC_API_KEY": os.environ.get("ANTHROPIC_NEW", ""), "OPENAI_API_KEY": os.environ.get("OPENAI_NEW", "")}
lines = open(path).read().split("\n")
out = []
for line in lines:
    name = line.split("=", 1)[0]
    out.append(f"{name}={new[name]}" if name in new and new[name] and "=" in line else line)
mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as fh:
    fh.write("\n".join(out))
os.chmod(tmp, mode)
os.replace(tmp, path)
PY
  echo "updated $(basename "$f")"
done
unset ak ok

recreate_workbench='(cd '"$HERE"'/.. && . ./env.sh && docker compose -f studios/investment.yml --env-file "$ENV_DIR/benchmark.env" up -d agent-service)'
recreate_witness='(cd '"$HERE"'/.. && . ./env.sh && docker compose -f studios/nuc.yml --env-file "$ENV_DIR/docker-compose.nuc.env" up -d agent-service)'
if [ "$restart" = 1 ]; then
  eval "$recreate_workbench" >/dev/null 2>&1 && echo "recreated the Investment workbench agent-service"
  eval "$recreate_witness" >/dev/null 2>&1 && echo "recreated the Witness agent-service"
else
  echo; echo "Services that read the keys at startup keep the old ones until recreated:"
  echo "  workbench: $recreate_workbench"
  echo "  witness:   $recreate_witness"
  echo "(or run this script with --restart). The benchmark's next case uses the new keys automatically."
fi
