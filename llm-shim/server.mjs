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
import { spawn } from "node:child_process";
import { ADAPTERS, adapterFor, detect } from "./adapters/index.mjs";
import { energyOf, powerConfig, readPlug } from "./power.mjs";

const PORT = Number(process.env.PORT || 8091);
const HOST = process.env.HOST || "0.0.0.0";
const SWITCH_CMD = process.env.SWITCH_CMD || "";
const POWER = powerConfig();
const IDLE_WATTS = process.env.POWER_IDLE_WATTS ? Number(process.env.POWER_IDLE_WATTS) : null;

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

  inFlight += 1;
  const soleAtStart = inFlight === 1;
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
    inFlight -= 1;
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
    inFlight -= 1;
    return;
  }

  const text = await upstream.text();
  let body = null;
  try { body = JSON.parse(text); } catch { /* not json */ }
  if (wantsMetrics && body) {
    body.local_metrics = await collect(adapter, { body, before, exclusive: exclusive() });
    inFlight -= 1;
    return json(res, upstream.status, body);
  }
  inFlight -= 1;
  res.writeHead(upstream.status, { "content-type": ct });
  res.end(text);
}

/** Start or stop engines through one script, with a fixed argument. */
function runSwitch(to) {
  switching = { to, startedAt: new Date().toISOString(), log: "" };
  const p = spawn(SWITCH_CMD, [to], { shell: false });
  const add = d => { switching.log = (switching.log + d.toString()).slice(-4000); };
  p.stdout.on("data", add);
  p.stderr.on("data", add);
  p.on("close", code => {
    switching = { ...switching, finishedAt: new Date().toISOString(), exitCode: code };
    active = adapterFor(to);
    setTimeout(() => { if (switching?.finishedAt) switching = null; }, 60_000);
  });
}

export const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  try {
    if (url.pathname === "/admin/status") {
      const states = {};
      for (const [id, a] of Object.entries(ADAPTERS)) states[id] = { name: a.name, url: a.baseUrl, health: await a.health() };
      const cur = await currentBackend();
      return json(res, 200, {
        backend: cur?.id ?? null,
        engines: states,
        switching,
        inFlight,
        power: { plug: POWER.url || null, idleWatts: IDLE_WATTS, schedule: POWER.schedule?.name ?? null },
        canSwitch: Boolean(SWITCH_CMD),
        lastRequest,
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
