// One interface, two local engines.
//
// An adapter knows three things the shim cannot know generically: where its
// engine listens, whether it is up, and how to get that engine's own account of
// a request out of it. Everything else -- proxying, energy, the concurrency
// gate -- is the same either way and lives in the shim.
//
// Adapters do NOT start or stop their engines. That needs root (systemd for
// llama.cpp, docker for vLLM), and a process that proxies untrusted request
// bodies should not also hold the right to run privileged commands. Switching
// shells out to one small script with a fixed set of arguments instead.

import { fromLlamaTimings, fromVllmCounters, parsePrometheus } from "../engine-metrics.mjs";

const timeout = ms => AbortSignal.timeout(ms);

export const llama = {
  name: "llama.cpp",
  id: "llama",
  baseUrl: process.env.LLAMA_BASE_URL || "http://172.18.0.1:8090",
  /** llama.cpp answers /health with 200 once the model is loaded. */
  async health() {
    try {
      const r = await fetch(`${this.baseUrl}/health`, { signal: timeout(2500) });
      return r.ok ? "up" : "down";
    } catch {
      return "down";
    }
  },
  /** Per-request and in-band: nothing to sample before. */
  async sampleBefore() {
    return null;
  },
  async sampleAfter() {
    return null;
  },
  /** llama.cpp puts its own timings in the response body. */
  fromBody(body) {
    return fromLlamaTimings(body?.timings);
  },
};

export const vllm = {
  name: "vLLM (radiance MXFP4)",
  id: "vllm",
  baseUrl: process.env.VLLM_BASE_URL || "http://172.18.0.1:8080",
  async health() {
    try {
      const r = await fetch(`${this.baseUrl}/health`, { signal: timeout(2500) });
      return r.ok ? "up" : "down";
    } catch {
      return "down";
    }
  },
  /** vLLM reports nothing per request, so its counters are bracketed instead. */
  async sampleBefore() {
    return counters(this.baseUrl);
  },
  async sampleAfter(before, opts) {
    return fromVllmCounters(before, await counters(this.baseUrl), opts);
  },
  fromBody() {
    return undefined;
  },
};

/** vLLM's Prometheus exposition, or null when it cannot be read. */
async function counters(baseUrl) {
  try {
    const r = await fetch(`${baseUrl}/metrics`, { signal: timeout(2500) });
    if (!r.ok) return null;
    return parsePrometheus(await r.text());
  } catch {
    return null;
  }
}

export const ADAPTERS = { llama, vllm };

/** The adapter named in the environment, defaulting to whichever is serving. */
export function adapterFor(id) {
  return ADAPTERS[id] ?? null;
}

/** Whichever engine is actually answering right now, or null if neither is. */
export async function detect() {
  for (const a of [vllm, llama]) {
    if ((await a.health()) === "up") return a;
  }
  return null;
}
