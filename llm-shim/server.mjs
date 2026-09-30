// A shim in front of the local inference engines.
//
// It does three things the studio cannot do for itself:
//
//   1. Speaks OpenAI to whichever engine is running, so the studio has one URL
//      and does not care which is behind it.
//   2. Puts a single, consistent metrics object into every response, built from
//      whatever that engine is willing to say about itself. llama.cpp reports
//      per-request timings in the body; vLLM reports engine-wide Prometheus
//      counters and nothing per request. Both come out the same shape here.
//   3. Measures what the request cost at the wall socket, which no engine knows.
//
// Zero dependencies, like the rest of this repo.
//
//   PORT (8091)  BACKEND (llama|vllm, default: whichever answers)
//   SHELLY_URL   POWER_IDLE_WATTS   POWER_RATE_SCHEDULE   POWER_HOLIDAYS
//   SWITCH_CMD   the privileged script that starts/stops engines

import http from "node:http";
import os from "node:os";
import { spawn } from "node:child_process";
import { ADAPTERS, adapterFor, detect } from "./adapters/index.mjs";
import { energyOf, powerConfig, readPlug } from "./power.mjs";
import { MODELS, modelFor, residentFrom } from "./models.mjs";
import { readGpu, readHost, queueFrom } from "./telemetry.mjs";

const PORT = Number(process.env.PORT || 8091);
const HOST = process.env.HOST || "0.0.0.0";
const SWITCH_CMD = process.env.SWITCH_CMD || "";
const POWER = powerConfig();
const IDLE_WATTS = process.env.POWER_IDLE_WATTS ? Number(process.env.POWER_IDLE_WATTS) : null;
// One card holds one model, and loading another takes minutes. Without a floor
// on how long a model stays put, two studios wanting different models would
// ping-pong the GPU and it would spend the day loading weights and answering
// nothing. Refusing is better than thrashing.
const MIN_RESIDENCY_MS = Number(process.env.MIN_RESIDENCY_MS || 10 * 60_000);
// What a cold start costs, for Retry-After. Only a hint: the real wait is
// whatever the engine takes, and the caller re-checks rather than trusting it.
const SWAP_HINT_S = Number(process.env.SWAP_HINT_S || 240);

// Requests in flight. The engine's own per-request numbers survive concurrency;
// anything BRACKETED does not. A wall-socket reading cannot be divided between
// two requests, and vLLM's counters are engine-wide, so both are reported only
// when a request had the machine to itself for its whole duration.
let inFlight = 0;
let active = null;                 // the adapter currently proxied to
let switching = null;              // { to, startedAt, log } while a switch runs
// The last request's metrics decision, so the admin page can say why a number
// is missing instead of showing a blank.
let lastRequest = null;
// Which model the engine says it is serving, and when we last looked. Read back
// from /v1/models rather than remembered from what we asked for.
let resident = null;
let residentAt = 0;
// Set when a switch completes, and spent by the first request after it, so a
// cold start is reported as its own number instead of landing inside that
// request\'s TTFT and making the model look catastrophically slow.
let pendingSwapMs = null;
let residentSince = 0;

const json = (res, code, body) => {
  const s = JSON.stringify(body);
  res.writeHead(code, { "content-type": "application/json", "content-length": Buffer.byteLength(s) });
  res.end(s);
};

async function currentBackend() {
  if (process.env.BACKEND && adapterFor(process.env.BACKEND)) return adapterFor(process.env.BACKEND);
  if (active && (await active.health()) === "up") return active;
  active = await detect();
  return active;
}

/**
 * Which model is loaded, according to the engine itself. Cached briefly so a
 * busy request path does not re-ask on every call, and cleared outright by a
 * switch. Believing our own record instead of asking is what let a failed start
 * leave a stale name behind and a whole sweep arm run against a dead engine.
 */
async function residentModel(adapter, { maxAgeMs = 5000 } = {}) {
  if (!adapter) return null;
  if (resident && Date.now() - residentAt < maxAgeMs) return resident;
  let served = [];
  try {
    const r = await fetch(`${adapter.baseUrl}/v1/models`, { signal: AbortSignal.timeout(2500) });
    if (r.ok) served = ((await r.json())?.data ?? []).map(m => m.id).filter(Boolean);
  } catch { /* engine down or starting */ }
  resident = residentFrom(served);
  residentAt = Date.now();
  return resident;
}

/** The metrics object every response carries, whichever engine served it. */
async function collect(adapter, { body, before, exclusive }) {
  const engine = adapter.fromBody(body) ?? (await adapter.sampleAfter(before?.counters, { exclusive }));
  const energy = energyOf(before?.power, await readPlug(POWER.url), {
    idleWatts: IDLE_WATTS,
    schedule: POWER.schedule,
    ratePerKwh: POWER.ratePerKwh,
  });
  const out = { engine: adapter.id };
  if (engine) out.server = engine;
  // Spent once. A cold start belongs to the switch, not to whichever request
  // happened to arrive first -- charging it to that request is the same
  // restart artifact that made every arm of the config sweep look better than
  // the baseline until each arm\'s first cell was dropped.
  if (pendingSwapMs != null) {
    out.swapMs = pendingSwapMs;
    pendingSwapMs = null;
  }
  // Energy is the whole machine's, so it is only this request's when this
  // request was the only one running. Absent beats wrong -- but say WHY it is
  // absent, or a null downstream is indistinguishable from a broken meter.
  if (!energy) out.energyOmitted = "no reading";
  else if (!exclusive) out.energyOmitted = "shared";
  else if (energy.wh === 0) out.energyOmitted = "below meter resolution";
  else out.energy = energy;
  lastRequest = {
    at: new Date().toISOString(),
    engine: adapter.id,
    exclusive,
    energy: out.energy ? { wh: out.energy.wh, meanWatts: out.energy.meanWatts } : null,
    energyOmitted: out.energyOmitted ?? null,
  };
  return out;
}

async function proxy(req, res, adapter) {
  const url = new URL(req.url, "http://x");
  const target = `${adapter.baseUrl}${url.pathname}${url.search}`;
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks);
  const wantsMetrics = url.pathname.endsWith("/chat/completions") || url.pathname.endsWith("/completions");

  // A request for a model that is not loaded is answered NOW, not held open
  // while the GPU loads it. agent-service gives this shim 300s and then retries
  // three times; a cold start is budgeted at 15-20 minutes by the switch
  // scripts themselves. Blocking would burn a quarter of an hour on a dead
  // spinner and end in a timeout that says nothing. A 503 that names what is
  // loaded and what was asked for is something a studio can actually render.
  if (wantsMetrics) {
    let want = null;
    try { want = modelFor(JSON.parse(raw.toString("utf8"))?.model); } catch { /* not json */ }
    const have = await residentModel(adapter);
    // Unknown ids fall through on purpose: the engine may serve names this
    // registry has never heard of, and its own error is better than our guess.
    if (want && have && want.id !== have.id) {
      const loading = switching && !switching.finishedAt ? switching.to : null;
      res.writeHead(503, { "content-type": "application/json", "retry-after": String(SWAP_HINT_S) });
      return res.end(JSON.stringify({
        error: {
          message: loading
            ? `loading ${loading}; ${have.name} is still serving. Retry shortly.`
            : `${want.name} is not loaded (${have.name} is). Switch models from the admin page, then retry.`,
          type: "model_not_resident",
          code: "model_not_resident",
        },
        requested: want.id,
        resident: have.id,
        loading,
      }));
    }
  }

  inFlight += 1;
  const soleAtStart = inFlight === 1;
  // Release the slot when the RESPONSE ends, however it ends -- not at the
  // bottom of this function. A client that disconnects mid-stream throws out of
  // the forwarding loop and never reaches a decrement, and the counter then
  // stays high for the life of the process. That is not a cosmetic leak:
  // everything downstream reads inFlight to decide whether a request had the
  // machine to itself, so ONE leak silently marks every later request "shared"
  // and suppresses its energy permanently. Idempotent because 'close' and
  // 'finish' can both fire.
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    inFlight -= 1;
  };
  res.on("close", release);
  res.on("finish", release);
  const before = wantsMetrics
    ? { power: await readPlug(POWER.url), counters: await adapter.sampleBefore() }
    : null;

  let upstream;
  try {
    upstream = await fetch(target, {
      method: req.method,
      headers: { "content-type": req.headers["content-type"] ?? "application/json" },
      body: ["GET", "HEAD"].includes(req.method) ? undefined : raw,
    });
  } catch (e) {
    release();
    return json(res, 502, { error: { message: `local inference server unreachable: ${e.message}` } });
  }

  const exclusive = () => soleAtStart && inFlight === 1;
  const ct = upstream.headers.get("content-type") ?? "application/json";

  // Streaming: forward every byte untouched, then add one well-formed chunk
  // carrying the metrics just before [DONE]. Adding rather than rewriting, so a
  // client that ignores the extra chunk behaves exactly as it did before.
  if (ct.includes("text/event-stream")) {
    res.writeHead(upstream.status, { "content-type": ct, "cache-control": "no-cache", connection: "keep-alive" });
    const reader = upstream.body.getReader();
    const dec = new TextDecoder();
    let pending = "";
    let lastChunk = null;
    // The upstream's own [DONE] must NOT be forwarded where it lands: a client
    // stops reading at the first one, so anything appended after it is never
    // seen. The first version of this wrote metrics AFTER the upstream
    // sentinel and they were silently dropped by the SDK -- the run looked
    // fine and every shim metric came back null. So the stream is forwarded
    // line-aware, the sentinel is held back, and it is re-emitted at the end
    // once the metrics chunk is in.
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      pending += dec.decode(value, { stream: true });
      // Keep the last partial line for the next read; forward whole ones.
      const cut = pending.lastIndexOf("\n");
      if (cut < 0) continue;
      const whole = pending.slice(0, cut + 1);
      pending = pending.slice(cut + 1);
      let out = "";
      for (const line of whole.split("\n")) {
        if (line.startsWith("data: ") && line.includes("[DONE]")) continue;
        if (line.startsWith("data: ")) {
          try { lastChunk = JSON.parse(line.slice(6)); } catch { /* partial or not json */ }
        }
        out += line + "\n";
      }
      if (out) res.write(out);
    }
    if (pending) res.write(pending);
    const metrics = await collect(adapter, { body: lastChunk, before, exclusive: exclusive() });
    res.write(`data: ${JSON.stringify({
      id: lastChunk?.id ?? "shim",
      object: "chat.completion.chunk",
      created: Math.floor(Date.now() / 1000),
      model: lastChunk?.model ?? "local",
      choices: [],
      local_metrics: metrics,
    })}\n\n`);
    res.end("data: [DONE]\n\n");
    release();
    return;
  }

  const text = await upstream.text();
  let body = null;
  try { body = JSON.parse(text); } catch { /* not json */ }
  if (wantsMetrics && body) {
    body.local_metrics = await collect(adapter, { body, before, exclusive: exclusive() });
    release();
    return json(res, upstream.status, body);
  }
  release();
  res.writeHead(upstream.status, { "content-type": ct });
  res.end(text);
}

/**
 * Load a model, through one script, with one key from a fixed set. The key
 * comes from the registry and never from a request body: this process proxies
 * untrusted bodies, so it must not be able to turn one into an argument to a
 * privileged command.
 */
function runSwitch(model) {
  const t0 = Date.now();
  switching = { to: model.id, key: model.key, startedAt: new Date().toISOString(), log: "" };
  // A DELIBERATELY NARROW environment. Node hands a child process.env by
  // default, and this service's own PORT=8091 then reached the launcher, which
  // reads PORT to decide where to serve: vLLM was told to bind the shim's port.
  // It failed in 700ms with "port already in use" and, worse, the health probe
  // that followed hit THIS process, got a 200, and reported the model as
  // serving when nothing had started. Pass only what the scripts need.
  const p = spawn(SWITCH_CMD, [model.key], {
    shell: false,
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      USER: process.env.USER,
      LOGNAME: process.env.LOGNAME,
      SHELL: process.env.SHELL,
      LANG: process.env.LANG,
    },
  });
  const add = d => { switching.log = (switching.log + d.toString()).slice(-4000); };
  p.stdout.on("data", add);
  p.stderr.on("data", add);
  p.on("close", code => {
    const ms = Date.now() - t0;
    switching = { ...switching, finishedAt: new Date().toISOString(), exitCode: code, ms };
    active = adapterFor(model.engine);
    // Force the next residency check to ask the engine rather than answer from
    // a cache that predates the switch.
    resident = null;
    residentAt = 0;
    if (code === 0) {
      pendingSwapMs = ms;
      residentSince = Date.now();
    }
    setTimeout(() => { if (switching?.finishedAt) switching = null; }, 60_000);
  });
}

/**
 * The engine's own queue gauges. vLLM exposes them; llama.cpp does not, so this
 * is null on that backend rather than an error -- the page simply omits the row.
 */
async function engineQueue(adapter) {
  if (!adapter?.baseUrl) return null;
  const r = await fetch(`${adapter.baseUrl}/metrics`, { signal: AbortSignal.timeout(2000) });
  if (!r.ok) return null;
  const { parsePrometheus } = await import("./engine-metrics.mjs");
  return queueFrom(parsePrometheus(await r.text()));
}

/** What the box is drawing at the wall, if a smart plug is configured. */
async function plugWatts() {
  if (!POWER.url) return null;
  const s = await readPlug(POWER.url, { timeoutMs: 2000 });
  return typeof s?.watts === "number" ? Math.round(s.watts) : null;
}

export const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  try {
    if (url.pathname === "/admin/status") {
      const states = {};
      for (const [id, a] of Object.entries(ADAPTERS)) states[id] = { name: a.name, url: a.baseUrl, health: await a.health() };
      const cur = await currentBackend();
      const have = await residentModel(cur, { maxAgeMs: 0 });
      const heldFor = residentSince ? Date.now() - residentSince : null;
      return json(res, 200, {
        backend: cur?.id ?? null,
        engines: states,
        // The model the ENGINE says it is serving, and everything we know how
        // to load. A studio addresses models by these ids; the engine behind
        // one is ours to change and not the studio\'s to know.
        model: have?.id ?? null,
        models: Object.entries(MODELS).map(([id, m]) => ({
          id, name: m.name, engine: m.engine, resident: have?.id === id,
        })),
        residency: { heldForMs: heldFor, minMs: MIN_RESIDENCY_MS,
                     canSwitchAt: heldFor != null && heldFor < MIN_RESIDENCY_MS
                       ? new Date(residentSince + MIN_RESIDENCY_MS).toISOString() : null },
        switching,
        inFlight,
        power: { plug: POWER.url || null, idleWatts: IDLE_WATTS, schedule: POWER.schedule?.name ?? null },
        canSwitch: Boolean(SWITCH_CMD),
        lastRequest,
        // Live telemetry for the page. Each is null when it cannot be read --
        // an absent sensor must not arrive as a zero, which reads as "idle".
        gpu: await readGpu().catch(() => null),
        host: await readHost(os.cpus().length).catch(() => null),
        queue: await engineQueue(cur).catch(() => null),
        wallWatts: await plugWatts().catch(() => null),
      });
    }
    if (url.pathname === "/admin/backend" && req.method === "POST") {
      const chunks = []; for await (const c of req) chunks.push(c);
      let to = "";
      try { to = JSON.parse(Buffer.concat(chunks).toString()).backend; } catch {}
      if (!adapterFor(to)) return json(res, 400, { error: `unknown backend: ${to}` });
      if (!SWITCH_CMD) return json(res, 501, { error: "no switch command configured (SWITCH_CMD)" });
      if (switching && !switching.finishedAt) return json(res, 409, { error: `already switching to ${switching.to}` });
      if (inFlight > 0) return json(res, 409, { error: `${inFlight} request(s) in flight; try again when idle` });
      runSwitch(to);
      return json(res, 202, { switching: true, to });
    }
    // Loading a model is an ADMIN action and never a side effect of a request.
    // The studio\'s model picker is configuration -- set rarely, deliberately,
    // by someone who is watching -- so that is when the cold start gets paid,
    // not four hours later when a user happens to send a message.
    if (url.pathname === "/admin/model" && req.method === "POST") {
      const chunks = []; for await (const c of req) chunks.push(c);
      let want = null;
      try { want = modelFor(JSON.parse(Buffer.concat(chunks).toString()).model); } catch {}
      if (!want) return json(res, 400, { error: "unknown model", models: Object.keys(MODELS) });
      if (!SWITCH_CMD) return json(res, 501, { error: "no switch command configured (SWITCH_CMD)" });
      if (switching && !switching.finishedAt) return json(res, 409, { error: `already loading ${switching.to}` });
      if (inFlight > 0) return json(res, 409, { error: `${inFlight} request(s) in flight; try again when idle` });
      const have = await residentModel(await currentBackend(), { maxAgeMs: 0 });
      if (have?.id === want.id) return json(res, 200, { model: want.id, alreadyResident: true });
      // The thrash guard. Forcing past it is allowed, but has to be asked for.
      const held = residentSince ? Date.now() - residentSince : Infinity;
      const force = new URL(req.url, "http://x").searchParams.get("force") === "1";
      if (held < MIN_RESIDENCY_MS && !force) {
        const waitS = Math.ceil((MIN_RESIDENCY_MS - held) / 1000);
        res.writeHead(409, { "content-type": "application/json", "retry-after": String(waitS) });
        return res.end(JSON.stringify({
          error: `${have?.name ?? "the current model"} has only been loaded ${Math.round(held / 1000)}s; `
               + `minimum residency is ${Math.round(MIN_RESIDENCY_MS / 1000)}s. Add ?force=1 to override.`,
          retryAfterS: waitS,
        }));
      }
      runSwitch(want);
      return json(res, 202, { loading: want.id, engine: want.engine, estimateS: SWAP_HINT_S });
    }
    if (url.pathname === "/admin" || url.pathname === "/admin/") {
      const { adminPage } = await import("./admin-page.mjs");
      const html = adminPage();
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end(html);
    }
    if (url.pathname === "/health") return json(res, 200, { ok: true, backend: (await currentBackend())?.id ?? null });

    const adapter = await currentBackend();
    if (!adapter) return json(res, 503, { error: { message: "no local inference engine is running" } });
    return await proxy(req, res, adapter);
  } catch (e) {
    return json(res, 500, { error: { message: e.message } });
  }
});

if (process.argv[1]?.endsWith("server.mjs")) {
  server.listen(PORT, HOST, () => console.log(`llm-shim on ${HOST}:${PORT}`));
}
