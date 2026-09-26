// One metrics shape, whichever engine is behind the shim.
//
// The two local engines report their own work in different places and different
// units, and neither reports it the way the studio wants to read it:
//
//   llama.cpp  puts a `timings` object in the response itself: prompt_n /
//              prompt_ms / predicted_n / predicted_ms / draft_n /
//              draft_n_accepted, per request.
//   vLLM       puts nothing in the response, and exposes Prometheus counters at
//              /metrics that are ENGINE-WIDE, not per request. Reading them is a
//              matter of bracketing: sample before, sample after, subtract.
//
// The studio should not have to know which is behind it. This turns either into
// the same object, so a metric that exists for one engine and not the other is
// absent rather than silently substituted by something measured differently.
//
// The observed rates the studio computes for itself (time to first token,
// thinking, wall clock) are deliberately NOT produced here: those are measured
// from the client side and work against anything.

const num = v => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const rate = (tokens, ms) =>
  ms > 0 && tokens > 0 ? Math.round((tokens / (ms / 1000)) * 10) / 10 : undefined;

/** llama.cpp's own per-request `timings`, if this response carries one. */
export function fromLlamaTimings(raw) {
  if (!raw || typeof raw !== "object") return undefined;
  const t = raw;
  const promptTokens = num(t.prompt_n);
  const promptMs = num(t.prompt_ms);
  const predictedTokens = num(t.predicted_n);
  const predictedMs = num(t.predicted_ms);
  const draftTokens = num(t.draft_n);
  const draftAccepted = num(t.draft_n_accepted);
  const out = {
    engine: "llama.cpp",
    source: "response",
    promptTokens,
    promptMs,
    promptTokensPerSec: num(t.prompt_per_second) ?? rate(promptTokens, promptMs),
    cachedTokens: num(t.cache_n),
    predictedTokens,
    predictedMs,
    predictedTokensPerSec: num(t.predicted_per_second) ?? rate(predictedTokens, predictedMs),
    draftTokens,
    draftAccepted,
    draftAcceptance:
      draftTokens > 0 && draftAccepted !== undefined
        ? Math.round((draftAccepted / draftTokens) * 1000) / 1000
        : undefined,
  };
  return Object.fromEntries(Object.entries(out).filter(([, v]) => v !== undefined));
}

/** Parse a Prometheus exposition into { name: value } for the counters we want. */
export function parsePrometheus(text = "") {
  const out = {};
  for (const line of String(text).split("\n")) {
    if (!line || line[0] === "#") continue;
    const m = /^(\S+?)(?:\{[^}]*\})?\s+(-?[\d.eE+]+)$/.exec(line.trim());
    if (!m) continue;
    const v = Number(m[2]);
    if (Number.isFinite(v)) out[m[1]] = (out[m[1]] ?? 0) + v;
  }
  return out;
}

/**
 * vLLM's engine-wide counters, as a delta across one request.
 *
 * Only meaningful when this request had the engine to itself: the counters are
 * global, so a second request overlapping this one lands in the same numbers and
 * both would claim all of it. The caller passes `exclusive: false` when it knows
 * that happened, and gets nothing rather than a number that is quietly the sum
 * of two requests.
 */
export function fromVllmCounters(before, after, { exclusive = true } = {}) {
  if (!before || !after || !exclusive) return undefined;
  const d = k => {
    const v = (after[k] ?? 0) - (before[k] ?? 0);
    return Number.isFinite(v) && v >= 0 ? v : undefined;
  };
  const predictedTokens = d("vllm:generation_tokens_total");
  const promptTokens = d("vllm:prompt_tokens_total");
  const itlSum = d("vllm:inter_token_latency_seconds_sum");
  const itlCount = d("vllm:inter_token_latency_seconds_count");
  const ttftSum = d("vllm:time_to_first_token_seconds_sum");
  const draftTokens = d("vllm:spec_decode_num_draft_tokens_total");
  const draftAccepted = d("vllm:spec_decode_num_accepted_tokens_total");
  const out = {
    engine: "vllm",
    source: "prometheus",
    promptTokens: promptTokens || undefined,
    // vLLM reports the time to first token, which for a reasoning model is
    // prompt processing only if nothing was thought first. Kept as its own
    // number rather than called prefill.
    firstTokenMs: ttftSum ? Math.round(ttftSum * 1000) : undefined,
    predictedTokens: predictedTokens || undefined,
    // Time spent generating, from vLLM's inter-token latency. The rate is
    // TOKENS over that time, not intervals over it: with speculative decoding an
    // interval is one engine STEP and a step emits several tokens (measured 3.6
    // on this box: 17,822 tokens across 4,922 intervals, which is what 7 drafts
    // at 36.6% acceptance buys). Dividing intervals by seconds gives steps per
    // second and reads three times too slow.
    predictedMs: itlSum ? Math.round(itlSum * 1000) : undefined,
    // The step count itself, not just the quotient. A request is several calls,
    // and tokens-per-step for the request is total tokens over total steps --
    // which cannot be recovered from per-call averages.
    steps: itlCount || undefined,
    tokensPerStep:
      itlCount > 0 && predictedTokens > 0
        ? Math.round((predictedTokens / itlCount) * 100) / 100
        : undefined,
    predictedTokensPerSec:
      itlSum > 0 && predictedTokens > 0
        ? Math.round((predictedTokens / itlSum) * 10) / 10
        : undefined,
    draftTokens: draftTokens || undefined,
    draftAccepted: draftAccepted || undefined,
    draftAcceptance:
      draftTokens > 0 && draftAccepted !== undefined
        ? Math.round((draftAccepted / draftTokens) * 1000) / 1000
        : undefined,
  };
  const kept = Object.fromEntries(Object.entries(out).filter(([, v]) => v !== undefined));
  return Object.keys(kept).length > 2 ? kept : undefined;
}
