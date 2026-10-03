// One interface, three local engines.
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

/**
 * Pure: llama.cpp's context window out of /props.
 *
 * vLLM publishes max_model_len on /v1/models; llama.cpp publishes nothing there
 * and puts n_ctx under /props instead, in a spot that has moved between builds.
 * Callers should not have to learn two engines' shapes, so the shim normalises
 * it and tries each place n_ctx has lived rather than pinning one.
 */
export function ctxFromProps(j) {
  const cands = [
    j?.default_generation_settings?.n_ctx,
    j?.default_generation_settings?.params?.n_ctx,
    j?.n_ctx,
  ];
  for (const c of cands) {
    const n = Number(c);
    // 0 is llama.cpp's "unset", not a real window, so it is not an answer.
    if (Number.isFinite(n) && n > 0) return n;
  }
  return null;
}

/**
 * Pure: the per-prompt image limit out of an engine's argv.
 *
 * vLLM publishes this nowhere -- not /v1/models, not /metrics, and there is no
 * config endpoint -- so the only honest source is the argv the engine was
 * started with. Accepts both spellings the flag has taken.
 *
 * null means "could not tell", which is NOT the same as 0. Zero is a real
 * answer meaning images are refused; null must leave the caller free to decide
 * rather than have it silently stop sending attachments.
 */
export function imageLimitFromArgs(argv) {
  const s = Array.isArray(argv) ? argv.join(" ") : String(argv ?? "");
  const m = /--limit-mm-per-prompt[.=]image[= ]+(\d+)/.exec(s)
    ?? /--limit-mm-per-prompt[= ]+(\{[^}]*"image"\s*:\s*(\d+)[^}]*\})/.exec(s);
  if (!m) return null;
  const n = Number(m[2] ?? m[1]);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/** The argv of the first running container whose name matches, or null. */
async function containerArgs(pattern) {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const run = promisify(execFile);
  try {
    const { stdout } = await run("docker", ["ps", "--format", "{{.Names}}"], { timeout: 3000 });
    const name = stdout.split("\n").map(x => x.trim()).find(x => x && pattern.test(x));
    if (!name) return null;
    const { stdout: raw } = await run("docker", ["inspect", name, "--format", "{{json .Args}}"], { timeout: 3000 });
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

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
  /**
   * llama.cpp reads images only with an --mmproj companion file loaded. No
   * profile in profiles.sh loads one, so this is 0 unless one appears -- read
   * from the unit rather than assumed, so it follows if that changes.
   */
  async imageLimit() {
    const { readFile } = await import("node:fs/promises");
    try {
      const unit = await readFile("/etc/systemd/system/llama-server.service", "utf8");
      return /--mmproj\b/.test(unit) ? 1 : 0;
    } catch {
      return null;
    }
  },
  /** The window the server was actually started with, not what a config claims. */
  async contextWindow() {
    try {
      const r = await fetch(`${this.baseUrl}/props`, { signal: timeout(2500) });
      return r.ok ? ctxFromProps(await r.json()) : null;
    } catch {
      return null;
    }
  },
};

export const vllm = {
  name: "vLLM (radiance MXFP4)",
  id: "vllm",
  /**
   * Observed from the running container rather than declared here: the value
   * lives in serve-sly.sh, and a copy kept in this file would be one more thing
   * to go stale the next time the engine config changes.
   */
  async imageLimit() {
    return imageLimitFromArgs(await containerArgs(/vllm/i));
  },
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

/**
 * Strata: an MoE runner that keeps experts in system RAM and caches the hot ones
 * in VRAM (serve-strata.sh). Its server answers in llama.cpp's names -- per
 * request `timings` in the body, n_ctx on /props -- so it reads like llama.cpp.
 * It binds 127.0.0.1 only, which is fine: the shim runs on the same host.
 */
export const strata = {
  name: "Strata (Qwen3.8-Flash-Next Coder)",
  id: "strata",
  baseUrl: process.env.STRATA_BASE_URL || "http://127.0.0.1:8092",
  async health() {
    try {
      const r = await fetch(`${this.baseUrl}/health`, { signal: timeout(2500) });
      return r.ok ? "up" : "down";
    } catch {
      return "down";
    }
  },
  async sampleBefore() {
    return null;
  },
  async sampleAfter() {
    return null;
  },
  fromBody(body) {
    const m = fromLlamaTimings(body?.timings);
    return m ? { ...m, engine: "strata" } : m;
  },
  /** The coder model is text only. */
  async imageLimit() {
    return 0;
  },
  async contextWindow() {
    try {
      const r = await fetch(`${this.baseUrl}/props`, { signal: timeout(2500) });
      const fromProps = r.ok ? ctxFromProps(await r.json()) : null;
      if (fromProps) return fromProps;
      const m = await fetch(`${this.baseUrl}/v1/models`, { signal: timeout(2500) });
      const n = m.ok ? Number((await m.json())?.data?.[0]?.meta?.n_ctx) : NaN;
      return Number.isFinite(n) && n > 0 ? n : null;
    } catch {
      return null;
    }
  },
};

export const ADAPTERS = { llama, vllm, strata };

/** The adapter named in the environment, defaulting to whichever is serving. */
export function adapterFor(id) {
  return ADAPTERS[id] ?? null;
}

/** Whichever engine is actually answering right now, or null if none is. */
export async function detect() {
  for (const a of [vllm, llama, strata]) {
    if ((await a.health()) === "up") return a;
  }
  return null;
}
