import test from "node:test";
import assert from "node:assert/strict";
import { fromLlamaTimings, fromVllmCounters, parsePrometheus } from "./engine-metrics.mjs";

test("llama.cpp's own per-request timings come through as they are", () => {
  // A real final chunk. The rates are the server's own quotients, taken rather
  // than recomputed: deriving them again here would produce a second, slightly
  // different number for the same request.
  const m = fromLlamaTimings({
    cache_n: 1024, prompt_n: 56, prompt_ms: 1414.915, prompt_per_second: 39.578,
    predicted_n: 40, predicted_ms: 824.998, predicted_per_second: 47.272,
    draft_n: 35, draft_n_accepted: 27,
  });
  assert.equal(m.engine, "llama.cpp");
  assert.equal(m.source, "response");
  assert.equal(m.promptTokensPerSec, 39.578);
  assert.equal(m.predictedTokensPerSec, 47.272);
  assert.equal(m.draftAcceptance, 0.771);
  assert.equal(m.cachedTokens, 1024);
  assert.equal(fromLlamaTimings(undefined), undefined);
});

test("vLLM's engine-wide counters become one request's numbers by subtraction", () => {
  // vLLM says nothing per request, so the counters are bracketed. These deltas
  // are one real case: 7,941 tokens at 57.9 ms between them.
  const before = parsePrometheus(`
vllm:generation_tokens_total{model_name="Qwen3.8"} 10000
vllm:inter_token_latency_seconds_sum{model_name="Qwen3.8"} 100
vllm:inter_token_latency_seconds_count{model_name="Qwen3.8"} 2000
vllm:spec_decode_num_draft_tokens_total{model_name="Qwen3.8"} 20000
vllm:spec_decode_num_accepted_tokens_total{model_name="Qwen3.8"} 7000
`);
  const after = parsePrometheus(`
vllm:generation_tokens_total{model_name="Qwen3.8"} 17941
vllm:inter_token_latency_seconds_sum{model_name="Qwen3.8"} 559.8
vllm:inter_token_latency_seconds_count{model_name="Qwen3.8"} 9941
vllm:spec_decode_num_draft_tokens_total{model_name="Qwen3.8"} 32291
vllm:spec_decode_num_accepted_tokens_total{model_name="Qwen3.8"} 11818
`);
  const m = fromVllmCounters(before, after);
  assert.equal(m.engine, "vllm");
  assert.equal(m.predictedTokens, 7941);
  // 7,941 tokens over 459.8 s of generation = 17.3 tok/s, and 7,941 tokens
  // across 7,941 intervals is 1.0 per step -- this fixture has speculation
  // switched off in effect, which is why the two coincide.
  assert.equal(m.predictedTokensPerSec, 17.3);
  assert.equal(m.tokensPerStep, 1);
  assert.equal(m.draftAcceptance, 0.392);
});

test("an engine step emits several tokens, and the rate must count tokens", () => {
  // The live engine after one run: 17,822 tokens across 4,922 intervals in
  // 284.77 s. An interval is a STEP, and speculation makes a step worth 3.62
  // tokens. Tokens over time gives 62.6 tok/s; intervals over time would give
  // 17.3 and be wrong by the speculation factor -- which is exactly the mistake
  // of reading "57.9 ms between intervals" as "57.9 ms per token".
  const before = parsePrometheus("vllm:generation_tokens_total 0\nvllm:inter_token_latency_seconds_sum 0\nvllm:inter_token_latency_seconds_count 0\n");
  const after = parsePrometheus("vllm:generation_tokens_total 17822\nvllm:inter_token_latency_seconds_sum 284.77\nvllm:inter_token_latency_seconds_count 4922\n");
  const m = fromVllmCounters(before, after);
  assert.equal(m.tokensPerStep, 3.62);
  assert.equal(m.predictedTokensPerSec, 62.6);
});

test("a request that shared the engine gets no bracketed numbers at all", () => {
  // The counters are global. Two overlapping requests both see the whole delta,
  // so each would claim the other's tokens. Absent beats double-counted.
  const before = parsePrometheus("vllm:generation_tokens_total 10\nvllm:inter_token_latency_seconds_sum 1\nvllm:inter_token_latency_seconds_count 10\n");
  const after = parsePrometheus("vllm:generation_tokens_total 99\nvllm:inter_token_latency_seconds_sum 9\nvllm:inter_token_latency_seconds_count 99\n");
  assert.ok(fromVllmCounters(before, after, { exclusive: true }));
  assert.equal(fromVllmCounters(before, after, { exclusive: false }), undefined);
  assert.equal(fromVllmCounters(null, after), undefined);
});

test("a counter that went backwards is a restart, not negative work", () => {
  const before = parsePrometheus("vllm:generation_tokens_total 900\nvllm:inter_token_latency_seconds_sum 90\nvllm:inter_token_latency_seconds_count 900\n");
  const after = parsePrometheus("vllm:generation_tokens_total 5\nvllm:inter_token_latency_seconds_sum 1\nvllm:inter_token_latency_seconds_count 5\n");
  assert.equal(fromVllmCounters(before, after), undefined);
});

test("labels are summed away, comments ignored", () => {
  const p = parsePrometheus(`# HELP vllm:generation_tokens_total total
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total{engine="0",model_name="a"} 5
vllm:generation_tokens_total{engine="1",model_name="a"} 7
not a metric line
`);
  assert.equal(p["vllm:generation_tokens_total"], 12);
});

test("vLLM prefix-cache hits are reported as cached prompt tokens and a rate", () => {
  // The same field llama.cpp fills per request, so the studio sees one number
  // whichever engine served the call.
  const before = {
    "vllm:prefix_cache_queries_total": 1000,
    "vllm:prefix_cache_hits_total": 400,
  };
  const after = {
    "vllm:prefix_cache_queries_total": 1500,
    "vllm:prefix_cache_hits_total": 850,
  };
  const m = fromVllmCounters(before, after, { exclusive: true });
  assert.equal(m.cachedTokens, 450);
  assert.equal(m.cacheHitRate, 0.9); // 450 of the 500 queried in this request
});

test("a request that queried no cache reports neither a count nor a rate", () => {
  // Real generation, so the result is an object at all -- fromVllmCounters
  // returns nothing for a delta that shows no activity whatsoever.
  const before = {
    "vllm:generation_tokens_total": 100,
    "vllm:inter_token_latency_seconds_sum": 1,
    "vllm:inter_token_latency_seconds_count": 100,
    "vllm:prefix_cache_queries_total": 7,
    "vllm:prefix_cache_hits_total": 7,
  };
  const after = {
    ...before,
    "vllm:generation_tokens_total": 150,
    "vllm:inter_token_latency_seconds_sum": 2,
    "vllm:inter_token_latency_seconds_count": 150,
  };
  const m = fromVllmCounters(before, after, { exclusive: true });
  assert.equal(m.predictedTokens, 50);
  assert.equal(m.cachedTokens, undefined);
  assert.equal(m.cacheHitRate, undefined);
});
