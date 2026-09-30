import { test } from "node:test";
import assert from "node:assert/strict";
import { parseLoad, queueFrom } from "./telemetry.mjs";

test("load is reported against core count, not as a bare number", () => {
  // 2.20 of 6 cores is ~37% busy. The raw figure alone means nothing without
  // knowing how many cores it is spread over.
  const l = parseLoad("2.20 2.67 2.52 3/812 91234", 6);
  assert.equal(l.load1, 2.2);
  assert.equal(l.cores, 6);
  assert.equal(l.busyPercent, 37);
  // A machine past its core count is pegged, not 150% busy.
  assert.equal(parseLoad("9.00 8 8", 6).busyPercent, 100);
  assert.equal(parseLoad("", 6), null);
  assert.equal(parseLoad("not a number", 6), null);
});

test("queue gauges come through, and kv usage becomes a readable percent", () => {
  const q = queueFrom({
    "vllm:num_requests_running": 1,
    "vllm:num_requests_waiting": 0,
    "vllm:num_preemptions_total": 0,
    "vllm:kv_cache_usage_perc": 0.12473118279569895,
  });
  assert.equal(q.running, 1);
  assert.equal(q.waiting, 0);
  // 0..1 in the metric, 0..100 on the page, one decimal -- enough to watch it
  // move without implying precision the gauge does not have.
  assert.equal(q.kvCacheUsedPercent, 12.5);
});

test("a sensor that is not exposed is absent, never zero", () => {
  // A zero here would read as "idle" or "cold", which is a different claim from
  // "this card does not report it". llama.cpp exposes none of these gauges, so
  // this is the normal case on that engine, not an error.
  assert.equal(queueFrom({}), null);
  const partial = queueFrom({ "vllm:num_requests_running": 2 });
  assert.equal(partial.running, 2);
  assert.ok(!("waiting" in partial), "absent gauge must not appear as 0");
});
