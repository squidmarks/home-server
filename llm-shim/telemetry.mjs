// GPU and host telemetry for the admin page.
//
// Read straight from sysfs and /proc, deliberately NOT from rocm-smi: that is a
// Python tool and costs about a second per call, and the page polls every four
// seconds. Everything here is a file read of a few bytes.
//
// Every field is optional. A missing file means that sensor is not exposed on
// this card or kernel, and the page should show nothing rather than a zero --
// a zero here reads as "idle" or "cold", which is a different claim from "we
// could not measure it".

import { readFile, readdir } from "node:fs/promises";

const read = async p => {
  try { return (await readFile(p, "utf8")).trim(); } catch { return null; }
};
const readNum = async (p, scale = 1) => {
  const t = await read(p);
  if (t == null) return undefined;
  const n = Number(t);
  return Number.isFinite(n) ? n / scale : undefined;
};

/**
 * The first AMD GPU under /sys/class/drm that reports a busy percentage.
 *
 * hwmon labels differ between cards, so temperatures are matched by their
 * `tempN_label` (edge / junction / mem) rather than by index: on this card
 * junction is temp2 today, and nothing guarantees that after a kernel bump.
 */
export async function readGpu(root = "/sys/class/drm") {
  let cards = [];
  try { cards = (await readdir(root)).filter(n => /^card\d+$/.test(n)); } catch { return null; }

  for (const card of cards.sort()) {
    const dev = `${root}/${card}/device`;
    const busy = await readNum(`${dev}/gpu_busy_percent`);
    if (busy === undefined) continue;

    const usedB = await readNum(`${dev}/mem_info_vram_used`);
    const totalB = await readNum(`${dev}/mem_info_vram_total`);

    const out = {
      busyPercent: busy,
      memBusyPercent: await readNum(`${dev}/mem_busy_percent`),
      vramUsedMiB: usedB === undefined ? undefined : Math.round(usedB / 1048576),
      vramTotalMiB: totalB === undefined ? undefined : Math.round(totalB / 1048576),
      temps: {},
    };

    let hwmons = [];
    try { hwmons = await readdir(`${dev}/hwmon`); } catch { /* no hwmon */ }
    for (const h of hwmons) {
      const base = `${dev}/hwmon/${h}`;
      // millidegrees -> degrees, microwatts -> watts
      for (const i of [1, 2, 3, 4]) {
        const label = await read(`${base}/temp${i}_label`);
        const val = await readNum(`${base}/temp${i}_input`, 1000);
        if (label && val !== undefined) out.temps[label] = Math.round(val);
      }
      const w = await readNum(`${base}/power1_average`, 1e6);
      if (w !== undefined) out.watts = Math.round(w);
      const fan = await readNum(`${base}/fan1_input`);
      if (fan !== undefined) out.fanRpm = fan;
    }
    return prune(out);
  }
  return null;
}

/** Pure: parse /proc/loadavg. `cores` turns the 1-minute figure into a percentage. */
export function parseLoad(text, cores) {
  const parts = String(text ?? "").trim().split(/\s+/);
  // Number("") is 0, not NaN, so an empty or missing /proc/loadavg would
  // otherwise report a confident 0% busy -- the exact "absent became zero"
  // failure this module exists to avoid.
  if (!parts[0]) return null;
  const one = Number(parts[0]);
  if (!Number.isFinite(one)) return null;
  const out = { load1: one, load5: Number(parts[1]), load15: Number(parts[2]), cores };
  if (cores > 0) out.busyPercent = Math.min(100, Math.round((one / cores) * 100));
  return prune(out);
}

export async function readHost(cores) {
  const t = await read("/proc/loadavg");
  return t == null ? null : parseLoad(t, cores);
}

/**
 * Pure: the queue gauges, from an already-parsed Prometheus map.
 *
 * `kvCacheUsedPercent` is the one worth watching. It is how much of the
 * allocated context window is actually holding tokens, which is the only
 * honest answer to "how much context do we really need" -- a window can be
 * allocated at 262144 and never exceed a fraction of it.
 */
export function queueFrom(counters = {}) {
  const g = k => (Number.isFinite(counters[k]) ? counters[k] : undefined);
  const kv = g("vllm:kv_cache_usage_perc");
  return prune({
    running: g("vllm:num_requests_running"),
    waiting: g("vllm:num_requests_waiting"),
    preemptions: g("vllm:num_preemptions_total"),
    kvCacheUsedPercent: kv === undefined ? undefined : Math.round(kv * 1000) / 10,
  });
}

function prune(o) {
  const out = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || (typeof v === "number" && !Number.isFinite(v))) continue;
    if (v && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 0) continue;
    out[k] = v;
  }
  return Object.keys(out).length ? out : null;
}
