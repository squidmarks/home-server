# Local inference + model benchmark: handoff (as of 2026-09-21)

Written for the agent picking this up. Everything here was done in one long session; the
repos are the source of truth, this is the map.

## Goal

Make the GPU box the local server and find out which local and hosted models can
**develop** agents (build them well, following the studio's guidance) and later **execute**
them. Investment returns are not the point. The Agent Studio exists so Scitara can replace
deterministic orchestrations with agents, so the bench doubles as the edge-case validation
tool for that (notes: `agent-studio/docs/agent-validation-with-the-bench.md`).

## Hardware and layout

- `ssh server` (Tailscale, user geoff): Gigabyte B360M DS3H, i5-9400F, 32 GB RAM, **AMD Radeon AI
  PRO R9700 (gfx1201, 32 GB)**, Ubuntu 26.04, Ubuntu's ROCm 7.1. ReBAR needed a BIOS mod. It also
  hosts Witness, Mongo and monitoring: the hosts were consolidated onto this one box and
  `server` now resolves to it. Details: memory file `project_gpu_box.md`.
- Two repos, deliberately separate:
  - `/Users/geoffgerhardt/code/agent-studio` (branch `geoff.gerhardt/agent-benchmark`): product
    code + bench code. Rule from the user: **no homelab/Tailscale/personal code here** (only the
    Witness engine is quasi-personal).
  - `/Users/geoffgerhardt/code/homelab` (local git, no remote yet): everything machine-specific.
    Deployed to the box by `./deploy.sh`; agent-studio is deployed by `homelab/sync-agent-studio.sh`.
- Box paths: `~/agent-studio` (synced checkout, stamped with `.build-info`), `~/infra`
  (deployed homelab), `~/models` (GGUFs), results in `~/agent-studio/scripts/bench/results/<run>/<label>/`.
  Env files (`*.env`, hold API keys) are gitignored; never print or paste keys.

## The model server (llama.cpp, HIP build e613ef2)

Model: **Qwen3.8-27B** (`UD-Q4_K_M`, dense, hybrid Gated DeltaNet: only 16 of 64 layers use full
attention, so 128K context is cheap). Served on `172.18.0.1:8090`, alias `local-qwen3.8-27b`,
thinking ON by default. Studios reach it via `LOCAL_LLM_BASE_URL`.

Switch config with named profiles (rewrites the systemd unit, restarts, waits for load):

    ssh server '~/infra/llama/profiles.sh list'
    ssh server '~/infra/llama/profiles.sh set mtp3'

Profiles: `base mtp2 mtp3 mtp5 mtp3-ngram ngram nopreserve q6 moe`. **Currently running: `mtp3`.**
Files in `~/models`: Qwen3.8-27B Q4_K_M and Q6_K, `mtp-Qwen3.8-27B-Q4_0.gguf` (MTP draft head),
Qwen3.6-35B-A3B Q4_K_M (MoE, downloaded, never served), older Qwen3-32B and two Qwen3-30B-A3B files.

Never restart llama-server while a bench case is running; it kills the case.

## What we learned about the model server

- We started on **Qwen3-32B** (older generation, dense) with thinking OFF, V-cache q4_0, YaRN x3.
  That was a weak configuration; it scored 0.447 on `inv-news-trader` vs 0.83-0.91 for hosted models.
- Time is **~88% decode, ~12% prefill** (prefill ~620 tok/s). Prefill is not the bottleneck.
- **MTP speculative decoding** (`--spec-type draft-mtp --spec-draft-n-max 3` plus the draft file)
  took decode from ~25 to **36-57 tok/s** with 63-78% draft acceptance. It only changes speed, not
  output distribution. Kept on.
- Thinking is the other big lever. `reasoning_effort` is per request (`chat_template_kwargs`).
  Probe on one opening turn: default ~19K chars of thinking (130 s, then 29 s on a repeat: **4.5x
  swing between identical requests**), xhigh ~14K, high ~1-2.6K, medium/low ~600-1.7K, off 0.
  **`minimal` and `max` crash Qwen's template (HTTP 500)**; removed from the launcher.
- Server-level knobs not yet tested: `--reasoning-budget`, `--no-reasoning-preserve` (default is
  preserve, which resends all earlier thinking each turn), Vulkan build (a Reddit user claims >10%
  faster decode), ROCm 10 + llama-cpp-rdna-boosts patches, radiance-vllm, DFlash2 (reported slower
  than MTP). Reddit is blocked for the tools; the user pastes text.

## The benchmark system (all in agent-studio unless noted)

- **Cases** (`scripts/bench/cases/*.json`): plain requests to the Investment Studio's development
  agent (no process hints). 5 committed `inv-*` cases (dca-daily, event-watcher, news-trader,
  order-sizer, trading-assistant); 4 `dev-*` drafts uncommitted.
- **Runner** (`scripts/bench/run-dev.mjs`, libs in `lib/`): simulated user (LLM) drives the
  conversation, then a blind judge + a rules engine grade it. 25 rules (code checks + judge, some
  "both"), studio-agnostic core plus `packs/investment.mjs`. Result JSON embeds the raw studio export
  so `regrade.mjs` / `rejudge.mjs` can re-grade later. Each case gets a fresh studio + empty
  `benchmark_run` DB, Alpaca paper account reset, DB archived beside the result.
- **Studio** (`profiles/benchmark/engine`): the "Investment Studio" (must not know it is being
  tested; `model-facing-text.test.ts` enforces no benchmark wording in model-facing text). Guidance is
  `engine/src/context/agent-builder.md`, currently hash **`26841fe353f3`** (commit 8726e4f). The
  `dev-full1` baseline used the old hash `a3b49ed95c15`, so old and new numbers are not comparable.
- **Model Bench UI** (`apps/bench-ui`, port 3400, container `bench-ui`): runs table (queued, running,
  finished), run page grid, result page, blind review, case editor, launcher. Jobs and runs are one
  view. Launcher supports **inference conditions** (reasoning effort / thinking off), **repeats**
  (1-5, shown as numbered runs with mean and spread), a server-setup label, cancel for queued jobs.
  Front end is modules (`public/app.js` router + `ui.js`, `result-parts.js`, `views-*.js`); back end
  `server.mjs` + `server/http.mjs` + `server/routes/{jobs,cases}.mjs`. `views.test.mjs` renders every
  page through the real router with a DOM stub; run `node --test --test-timeout=25000` in the app.
- **Orchestration** (homelab): `bench/worker.sh` (systemd `bench-worker`) takes one job at a time from
  the UI queue and loops over conditions; `bench/bench-dev.sh` per case; `bench/probe.sh` runs
  `scripts/bench/probe-local.mjs` (a few-minute look at thinking settings on one realistic turn).
  Result column label = `<model>--<server label>--<condition>[--rN]`.
- **Timing (new, committed, NOT yet deployed to the studio image)**: agent-service now returns
  `metadata.timing` per request (`ttftMs`, `tokensPerSec`, `llmMs`, `outputTokens`, `calls`,
  `last*`), stored in the request record; the studio-web context-ring popup shows First token and
  Speed; the bench shows `elapsed · first token · tok/s` on its own line. Scope: router LLM calls
  only (sub-agent calls in `agent_test` are not timed); rate excludes tool time. Until the studio image
  is rebuilt, results show the client-side first-token wait and no rate.

## Results so far (single runs unless stated; score = rules earned, partial = half)

Qwen3.8-27B, `base` profile (no MTP), new guidance, thinking default:
news-trader 0.952 (37 min), dca-daily 0.905 (33 min), order-sizer 0.969 (19 min),
trading-assistant 0.947 (16 min). Low/medium effort single runs: trading-assistant low 0.972 (9.6 min),
medium 1.000 (7.5 min); order-sizer low 0.882 (19.7 min), medium 0.971 (9.8 min). These are inside
run-to-run noise; do not conclude anything from single runs.

Hosted models on the OLD guidance (`dev-full1`, news-trader): haiku 0.825, sonnet-5 0.875, gpt-5-mini
0.69, gpt-5 0.909 (40 min, 115 tool calls). Mean over 5 cases: sonnet-5 0.869 ($3.48), haiku 0.826.

**Phase 1 (in flight when I stopped): run `q38-effort`**, job `job-20260921173825-78g`: order-sizer +
trading-assistant x {default thinking, effort high, effort medium} x 3 repeats on the `mtp3` profile,
18 cells, ~2-3 h. Last known: 6 of 18 finished (default-thinking order-sizer runs scored 94%, 100%,
100% at 17-24 min; trading-assistant default run 1 100% in 11.6 min); effort-high sizer running.
I could not check after that: `ssh server` stopped resolving (Tailscale/DNS) at the end of the session.

## Next steps (agreed plan)

1. When `q38-effort` finishes, read the spread per condition (mean and spread are on the run page) and
   pick the thinking setting. Then **rebuild the studio image** so results carry server timing:
   `ssh server 'cd ~/infra/studios && BENCHMARK_STATE_DIR=/tmp/unused docker compose -p benchmark-studio --env-file ~/agent-studio/benchmark.env -f investment.yml build agent-service'`.
   Do not rebuild mid-experiment (it changes the code version between cells).
2. Cheap speed probes on the chosen thinking setting: MTP n-max 2/3/5, `mtp3-ngram`, Q6, MoE
   (`probe.sh`). Then a quality run of the MoE (`profiles.sh set moe`, model alias `local-qwen3.6-35b-a3b`;
   needs a registry entry in `apps/agent-service/src/llm/models/local.json` and a cost entry) and an
   A/B of `nopreserve`.
3. **Phase 2**: lock the local profile, run all five cases x 3 repeats locally and on Haiku, Sonnet 5,
   gpt-5-mini, gpt-5 with the new guidance. Hosted runs cost money (~$3.5 per 5 cases on Sonnet, x3).
4. Ideas parked: GPT-5 cross-judge on a sample (Claude-judge bias check), execution stage (run the
   built agents against scenarios), helper-model dollar costs, Shelly plug for energy cost of local
   runs, "load a run into the studio" button, production Witness restart to pick up new API keys
   (needs the user's go), push both repos once the user supplies credentials.

## Gotchas (each of these bit us)

- `pkill -f` and `docker ps --filter ancestor=node:22-slim` match too much (killed our own SSH session
  and our own probe). Kill by exact PID/name; bench containers are now named `bench-runner`, `bench-probe`.
- Restarting `bench-worker` mid-job used to re-run the job; fixed (claim file, `deploy.sh` refuses to
  restart the worker while a job runs). Still: never restart llama-server or the worker mid-case.
- The tool shell blocks in this app render a **Run button**; don't show commands you don't want the
  user to click. Terminal commands shown for information should be described inline.
- Prettier/lint-staged runs on commit and can reformat files (it changed the guidance hash once).
  Check the hash after committing guidance.
- The `dist/` of `packages/db` must be rebuilt (`npm run build` in the package) for agent-service to see
  schema type changes. `capture.test.ts` in agent-service fails only because `vitest` isn't installed
  (pre-existing).
- Tailscale SSH asks for a browser re-auth periodically; ask the user to open the link.
- Web tools can't open reddit.com; browser-pane site permissions are the user's to change.

## How the user likes to work

Conversational questions, not multiple choice. Recommends, decides, expects you to act on clear
direction. Wants no hand-grading, the studio to never know it is tested, results kept per run with the
DB archived, and honest reporting (say when a number is noise, when you broke something, when you
couldn't verify). Memory notes for this project are in
`~/.claude/projects/-Users-geoffgerhardt-code-agent-studio/memory/` (index in `MEMORY.md`).
