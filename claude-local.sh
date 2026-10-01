#!/usr/bin/env bash
# Run Claude Code against the local inference server instead of Anthropic.
#
#   ./claude-local.sh                 whatever model is loaded on the card
#   ./claude-local.sh --model <id>    a specific one (must already be loaded)
#   ./claude-local.sh -- <args>       anything else goes to claude
#
# There is deliberately nothing to revert. This sets the environment for ONE
# invocation, so plain `claude` still goes to Anthropic and you cannot leave a
# shell quietly pointed at the GPU box. Exporting these in your profile instead
# would work right up until you forgot.
#
# Why each variable:
#   ANTHROPIC_BASE_URL   the shim, which proxies /v1/messages to whichever
#                        engine is up. vLLM serves the Anthropic Messages API
#                        natively, so no translation layer is involved.
#   ANTHROPIC_AUTH_TOKEN any non-empty value; the shim does not check it. The
#                        client refuses to start without one.
#   CLAUDE_CODE_ATTRIBUTION_HEADER=0
#                        Claude Code otherwise adds a header that changes on
#                        every request, which defeats the engine's prefix cache
#                        and makes it reprocess the whole conversation each turn.
set -euo pipefail

: "${TAILNET_FQDN:=}"
if [ -z "$TAILNET_FQDN" ] && [ -f "$(dirname "$0")/env.sh" ]; then
  # env.sh keeps the tailnet name out of the repo; read it rather than hardcode.
  . "$(dirname "$0")/env.sh"
fi
# MagicDNS resolves the short name on the tailnet, so this needs no config in
# the common case. TAILNET_FQDN (from env.sh, kept out of the repo) and
# INFERENCE_HOST override it for anywhere that cannot resolve it.
HOST="${INFERENCE_HOST:-${TAILNET_FQDN:-server}}"
BASE="${SHIM_BASE_URL:-http://${HOST}:8091}"

want=""
# ${args[@]+...} rather than "${args[@]}": macOS ships bash 3.2, where expanding
# an empty array under `set -u` is an unbound-variable error.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --model) want="${2:?--model needs a value}"; shift 2 ;;
    --) shift; [ $# -gt 0 ] && args+=("$@"); break ;;
    *) args+=("$1"); shift ;;
  esac
done

# Which model is on the card. Asked rather than assumed: the card holds one at a
# time and the answer changes, so a name baked in here would be wrong the first
# time anyone switched engines.
status=$(curl -fsS --max-time 8 "$BASE/admin/status" 2>/dev/null) || {
  echo "!! $BASE is not answering. Is the box up, and are you on the tailnet?" >&2
  exit 3
}
resident=$(printf '%s' "$status" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d.get("model") or "")')
if [ -z "$resident" ]; then
  echo "!! no model is loaded on the card; load one at $BASE/admin first" >&2
  exit 4
fi
if [ -n "$want" ] && [ "$want" != "$resident" ]; then
  echo "!! $want is not the loaded model ($resident is)." >&2
  echo "   The card holds one at a time. Load it at $BASE/admin, then retry." >&2
  exit 5
fi
model="${want:-$resident}"

ctx=$(curl -fsS --max-time 8 "$BASE/v1/models" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)["data"][0]
    print(d.get("max_model_len") or "?")
except Exception:
    print("?")')

cat >&2 <<EOF
>>> Claude Code -> $BASE
    model     $model
    context   $ctx tokens (Anthropic models give you far more)
    note      this holds the GPU: studios pointed at the same box will wait,
              and the shim enforces a 10 minute minimum residency.
EOF

exec env \
  ANTHROPIC_BASE_URL="$BASE" \
  ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-local}" \
  CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
  claude --model "$model" ${args[@]+"${args[@]}"}
