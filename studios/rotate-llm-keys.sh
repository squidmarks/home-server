#!/usr/bin/env bash
# Replace the Anthropic and OpenAI API keys in the env files on this machine that hold them.
#   ~/infra/studios/rotate-llm-keys.sh [--restart] [--include-production] [--from-file FILE]
# (run it directly on the box, in your own terminal: no ssh is needed from the box itself)
#
# By default the keys are typed or pasted at a silent prompt (you see nothing as you paste; it
# reports how many characters arrived, never the key). If pasting into a silent prompt is
# awkward, use --from-file: a file you edit yourself (nano works) with the lines
#   ANTHROPIC_API_KEY=...   OPENAI_API_KEY=...   ANTHROPIC_WORKSPACE_ID=...
# (any may be left out); pass its path, then delete it (shred -u FILE). Keys are never passed
# as arguments, never printed, and never written anywhere except the env files. Each new key is
# checked against its provider first, and nothing is changed unless every key you entered is
# accepted.
#
# ANTHROPIC_WORKSPACE_ID (wrkspc_..., not a secret) is needed only for Anthropic keys that are not
# scoped to a workspace; it is sent as a header with every request.
#
# The production Witness env files (docker-compose.server.env, docker-compose.vps.env) are left
# alone unless --include-production is given. --restart recreates the services that read the
# keys at startup (the Investment workbench; also the production Witness agent-service with
# --include-production; a few seconds of downtime each). Without it the script prints the
# commands. The benchmark's throwaway studio picks the keys up on its next case.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

restart=0; from_file=""; include_prod=0
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) restart=1 ;;
    --include-production) include_prod=1 ;;
    --from-file) shift; from_file="${1:?--from-file needs a path}" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
files=$(grep -lE '^(ANTHROPIC|OPENAI)_API_KEY=' "$ENV_DIR"/*.env 2>/dev/null || true)
# The production Witness env files are left alone unless asked: its image may predate a key type
# (for example one that needs ANTHROPIC_WORKSPACE_ID), and a bad key there breaks a live service.
if [ "$include_prod" != 1 ]; then
  skipped=$(printf '%s\n' "$files" | grep -E '/docker-compose\.(server|vps)\.env$' || true)
  files=$(printf '%s\n' "$files" | grep -vE '/docker-compose\.(server|vps)\.env$' || true)
fi
# Never rewrite the file the new keys were read from.
[ -z "$from_file" ] || files=$(printf '%s\n' "$files" | grep -vxF "$(cd "$(dirname "$from_file")" && pwd)/$(basename "$from_file")" || true)
[ -n "$files" ] || { echo "no env files with LLM keys found in $ENV_DIR" >&2; exit 1; }
echo "These env files hold LLM keys and will be updated:"
echo "$files" | sed 's#^#  #'
[ -z "${skipped:-}" ] || { echo "Left alone (production; add --include-production to update them):"; echo "$skipped" | sed 's#^#  #'; }
echo

# Pasted text can carry terminal "bracketed paste" markers, spaces or a newline; keep only the key.
clean() { local v="$1"; v=${v//$'\e[200~'/}; v=${v//$'\e[201~'/}; printf '%s' "$v" | tr -d '[:space:]'; }

ak=""; ok=""; ws=""
if [ -n "$from_file" ]; then
  [ -r "$from_file" ] || { echo "cannot read $from_file" >&2; exit 1; }
  [ -z "$(find "$from_file" -perm /077 2>/dev/null)" ] || echo "warning: $from_file is readable by other users; run chmod 600 on it" >&2
  ak=$(clean "$(grep -E '^ANTHROPIC_API_KEY=' "$from_file" | head -1 | cut -d= -f2-)")
  ok=$(clean "$(grep -E '^OPENAI_API_KEY=' "$from_file" | head -1 | cut -d= -f2-)")
  ws=$(clean "$(grep -E '^ANTHROPIC_WORKSPACE_ID=' "$from_file" | head -1 | cut -d= -f2-)")
else
  # Read from the terminal itself, so this works however stdin is arranged.
  if ! { : < /dev/tty; } 2>/dev/null; then
    echo "This needs an interactive terminal (ssh -t ...), not a button or a pipe." >&2
    echo "Or put the keys in a file you edit yourself and use --from-file (see the top of this script)." >&2
    exit 1
  fi
  read -rsp "New Anthropic API key (blank to leave it alone): " ak < /dev/tty; echo
  read -rsp "New OpenAI API key (blank to leave it alone): " ok < /dev/tty; echo
  ak=$(clean "$ak"); ok=$(clean "$ok")
  if [ -n "$ak" ]; then
    read -rp "Anthropic workspace ID, e.g. wrkspc_... (blank if the key is scoped to a workspace): " ws < /dev/tty
    ws=$(clean "$ws")
  fi
fi

# Say what arrived without showing it.
report() { # label value expected-prefix
  if [ -z "$2" ]; then echo "  $1: nothing received (left as it is)"; return; fi
  local note=""; [[ "$2" == $3* ]] || note=" - does not start with $3, so it may not be the right kind of key"
  echo "  $1: received ${#2} characters$note"
}
echo "Received:"; report Anthropic "$ak" "sk-ant-"; report OpenAI "$ok" "sk-"
[ -z "$ws" ] || echo "  Anthropic workspace ID: $ws"
if [ -z "$ak$ok" ]; then
  echo "Nothing to change. If you pasted and nothing arrived, try --from-file (see the top of this script)." >&2
  exit 0
fi

# The key goes to curl on stdin as config, so it never appears in a process list.
check() { # provider key
  local out code body msg
  case "$1" in
    anthropic) out=$(printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n%s' "$2" "${ws:+header = \"anthropic-workspace-id: $ws\"$'\n'}" | curl -s -w '\n%{http_code}' -K - https://api.anthropic.com/v1/models) ;;
    openai)    out=$(printf 'header = "Authorization: Bearer %s"\n' "$2" | curl -s -w '\n%{http_code}' -K - https://api.openai.com/v1/models) ;;
  esac
  code=${out##*$'\n'}; body=${out%$'\n'*}
  if [ "$code" = "200" ]; then echo "  $1: accepted"; return 0; fi
  # The provider's own explanation (never the key: anything key-shaped is masked).
  msg=$(printf '%s' "$body" | python3 -c 'import sys,json,re
try:
    d=json.load(sys.stdin); e=d.get("error",d); m=e.get("message","") if isinstance(e,dict) else str(e)
except Exception:
    m=""
print(re.sub(r"sk-[A-Za-z0-9_*.\-]+","sk-...",m)[:240])' 2>/dev/null)
  echo "  $1: NOT accepted (HTTP $code)${msg:+: $msg}; nothing was changed" >&2
  return 1
}
if [ -z "${SKIP_KEY_CHECK:-}" ]; then
  echo "Checking the keys with their providers..."
  bad=0
  [ -z "$ak" ] || check anthropic "$ak" || bad=1
  [ -z "$ok" ] || check openai "$ok" || bad=1
  if [ "$bad" = 1 ]; then
    echo >&2
    echo "Nothing was changed. If the message mentions a workspace: create the key inside a workspace in the" >&2
    echo "provider's console (an unscoped key needs an extra request header that our services don't send)." >&2
    exit 1
  fi
fi

for f in $files; do
  ANTHROPIC_NEW="$ak" OPENAI_NEW="$ok" WORKSPACE_NEW="$ws" python3 - "$f" <<'PY'
import os, sys, tempfile
path = sys.argv[1]
new = {"ANTHROPIC_API_KEY": os.environ.get("ANTHROPIC_NEW", ""), "OPENAI_API_KEY": os.environ.get("OPENAI_NEW", ""), "ANTHROPIC_WORKSPACE_ID": os.environ.get("WORKSPACE_NEW", "")}
lines = open(path).read().split("\n")
out = []
if new["ANTHROPIC_API_KEY"] and new["ANTHROPIC_WORKSPACE_ID"] and not any(l.startswith("ANTHROPIC_WORKSPACE_ID=") for l in lines):
    lines = [l for l in lines if l != ""] + ["ANTHROPIC_WORKSPACE_ID=" + new["ANTHROPIC_WORKSPACE_ID"], ""]
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
recreate_witness='(cd '"$HERE"'/.. && . ./env.sh && docker compose -f studios/server.yml --env-file "$ENV_DIR/docker-compose.server.env" up -d agent-service)'
if [ "$restart" = 1 ]; then
  eval "$recreate_workbench" >/dev/null 2>&1 && echo "recreated the Investment workbench agent-service"
  if [ "$include_prod" = 1 ]; then eval "$recreate_witness" >/dev/null 2>&1 && echo "recreated the Witness agent-service"; fi
else
  echo; echo "Services that read the keys at startup keep the old ones until recreated:"
  echo "  workbench: $recreate_workbench"
  [ "$include_prod" != 1 ] || echo "  witness:   $recreate_witness"
  echo "(or run this script with --restart). The benchmark's next case uses the new keys automatically."
fi
