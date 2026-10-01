# Where things live on this machine. Sourced by the scripts in bench/ and studios/.
# Override any of these in the environment; the defaults match the home server.
_HL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Machine-local settings that must stay out of this public repo (the inference
# box's tailnet name, say) go in a gitignored .env beside this file. The
# environment still wins: a key already set is left alone.
if [ -f "$_HL_DIR/.env" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in ''|\#*) continue ;; esac
    [ -z "${!_k+x}" ] && export "$_k=$_v"
  done < "$_HL_DIR/.env"
  unset _k _v
fi
export AGENT_STUDIO_DIR="${AGENT_STUDIO_DIR:-$HOME/agent-studio}"          # checkout of the agent-studio repo
BENCH_DIR="${BENCH_DIR:-$AGENT_STUDIO_DIR/scripts/bench}"                   # the benchmark code (from agent-studio)
ENV_DIR="${ENV_DIR:-$AGENT_STUDIO_DIR}"                                     # where the *.env files live (never in git)
STUDIOS_DIR="${STUDIOS_DIR:-$_HL_DIR/studios}"                              # the studio compose files
MONGO_CONTAINER="${MONGO_CONTAINER:-mongo-mongo-1}"                         # the shared MongoDB container
MONGO_HOST="${MONGO_HOST:-mongo}"                                           # its name on the docker network
MONGO_ENV="${MONGO_ENV:-$HOME/infra/mongo/.env}"                            # holds MONGO_ROOT_PASSWORD
DOCKER_NETWORK="${DOCKER_NETWORK:-platform}"                                # shared network for mongo, llama-server, studios
# The inference box's tailnet name, when the bench runs elsewhere (on home).
# Unset means this IS the inference box, where the shim is on the docker gateway.
export INFERENCE_FQDN="${INFERENCE_FQDN:-}"
if [ -n "$INFERENCE_FQDN" ]; then _SHIM="http://$INFERENCE_FQDN:8091"; else _SHIM="http://172.18.0.1:8091"; fi
export SHIM_ADMIN_URL="${SHIM_ADMIN_URL:-$_SHIM}"   # /admin/status, /admin/profile
export SHIM_BASE_URL="${SHIM_BASE_URL:-$_SHIM/v1}"  # the OpenAI-compatible API
unset _SHIM
# llama-server's own /metrics is on the inference box's docker gateway only, so
# from another box there is none (the shim's per-request metrics remain).
if [ -n "$INFERENCE_FQDN" ]; then
  export LLAMA_METRICS_URL="${LLAMA_METRICS_URL:-}"
else
  export LLAMA_METRICS_URL="${LLAMA_METRICS_URL:-http://172.18.0.1:8090/metrics}"
fi
export RUN_STATE_DIR="${RUN_STATE_DIR:-$ENV_DIR/benchmark-run-state}"
export BENCHMARK_STATE_DIR="${BENCHMARK_STATE_DIR:-$ENV_DIR/benchmark-state}"
# The box's own tailnet name. `tailscale serve` answers on the FQDN and nothing
# else, so any URL that points at a served port has to use it -- a link built
# from whatever hostname a page was opened at does not connect. Deliberately
# has no default: it identifies a private network, so it lives in the
# environment (or a gitignored .env) rather than in a public repo. Unset means
# port links and generated hosts are left blank rather than silently wrong.
export TAILNET_FQDN="${TAILNET_FQDN:-}"

export BENCH_USER_EMAIL="${BENCH_USER_EMAIL:-geoff.gerhardt@gmail.com}"                # studio user that owns the Witness agents
# Stamped by sync-agent-studio.sh and read fresh on every job. It must NOT fall back
# to an inherited BENCH_CODE_VERSION: the worker is a long-lived service that exports
# its environment to each job it starts, so a sync during its lifetime would keep
# stamping results with the version the worker booted on. Override with
# BENCH_CODE_VERSION_OVERRIDE when a result really has to claim something else.
export BENCH_CODE_VERSION="${BENCH_CODE_VERSION_OVERRIDE:-$(cat "$AGENT_STUDIO_DIR/.build-info" 2>/dev/null || echo unknown)}"

# The smart plug the box is on, so a case can say what it cost at the wall.
# Unset means no measurement (which is different from zero). The rate is stored
# with each result, so a tariff change does not silently rewrite old costs.
export SHELLY_URL="${SHELLY_URL:-http://192.168.68.112}"
export POWER_RATE_PER_KWH="${POWER_RATE_PER_KWH:-}"
# What the box draws doing nothing. Re-measure it when the resident model
# changes: a loaded 27B idles differently from an empty card.
export POWER_IDLE_WATTS="${POWER_IDLE_WATTS:-50}"
