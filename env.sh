# Where things live on this machine. Sourced by the scripts in bench/ and studios/.
# Override any of these in the environment; the defaults match the home server.
_HL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export AGENT_STUDIO_DIR="${AGENT_STUDIO_DIR:-$HOME/agent-studio}"          # checkout of the agent-studio repo
BENCH_DIR="${BENCH_DIR:-$AGENT_STUDIO_DIR/scripts/bench}"                   # the benchmark code (from agent-studio)
ENV_DIR="${ENV_DIR:-$AGENT_STUDIO_DIR}"                                     # where the *.env files live (never in git)
STUDIOS_DIR="${STUDIOS_DIR:-$_HL_DIR/studios}"                              # the studio compose files
MONGO_CONTAINER="${MONGO_CONTAINER:-mongo-mongo-1}"                         # the shared MongoDB container
MONGO_HOST="${MONGO_HOST:-mongo}"                                           # its name on the docker network
MONGO_ENV="${MONGO_ENV:-$HOME/infra/mongo/.env}"                            # holds MONGO_ROOT_PASSWORD
DOCKER_NETWORK="${DOCKER_NETWORK:-platform}"                                # shared network for mongo, llama-server, studios
export LLAMA_METRICS_URL="${LLAMA_METRICS_URL:-http://172.18.0.1:8090/metrics}"
export RUN_STATE_DIR="${RUN_STATE_DIR:-$ENV_DIR/benchmark-run-state}"
export BENCHMARK_STATE_DIR="${BENCHMARK_STATE_DIR:-$ENV_DIR/benchmark-state}"
export BENCH_USER_EMAIL="${BENCH_USER_EMAIL:-geoff.gerhardt@gmail.com}"                # studio user that owns the Witness agents
