// What a case cost in electricity, measured at the wall.
//
// A Shelly smart plug (Gen2+ RPC, tested on a Plug US Gen4) reports a monotonic
// watt-hour counter, `aenergy.total`. Reading it at the start and end of a case
// and subtracting gives that case's energy exactly.
//
// Deliberately the counter and NOT samples of `apower`. The device already
// integrates power over time; sampling watts ourselves and integrating would
// alias badly on a load that swings between prefill, decode and waiting on a
// tool, and it would be our arithmetic rather than a measurement. This codebase
// has twice reported a derived number as a measured one; the accumulator is
// there, so it gets used.
//
// What it cannot do is separate the GPU from the rest of the box. The plug sees
// the whole machine, so `wh` is "what running this case cost", inclusive of the
// studio containers and everything else resident. `idleWatts`, sampled next to
// the run rather than remembered from another day, is what makes a marginal
// figure possible.

import { NS_POWER_RATES, blendedRate } from "./rate-schedule.mjs";

const RPC = "/rpc/Switch.GetStatus?id=0";

/** One reading, or null when the plug cannot be reached. Never throws: a
 *  benchmark must not fail because a power meter is offline. */
export async function readPlug(baseUrl, { timeoutMs = 4000, fetchImpl = fetch } = {}) {
  if (!baseUrl) return null;
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchImpl(`${baseUrl.replace(/\/+$/, "")}${RPC}`, { signal: ctl.signal });
    if (!res.ok) return null;
    const d = await res.json();
    const wh = d?.aenergy?.total;
    const watts = d?.apower;
    if (typeof wh !== "number") return null;
    return { wh, watts: typeof watts === "number" ? watts : null, at: new Date().toISOString() };
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

/**
 * The energy a case used, from two readings of the counter.
 *
 * Returns null unless both readings exist and the counter moved forward: a
 * Shelly's total resets when the device is re-flashed or its energy data is
 * cleared, and a negative delta means the pair straddles such a reset. Reporting
 * a reset as "used -412 Wh" would be worse than reporting nothing.
 */
export function energyOf(before, after, { ratePerKwh = null, idleWatts = null, schedule = null } = {}) {
  if (!before || !after) return null;
  const wh = Math.round((after.wh - before.wh) * 1000) / 1000;
  if (!(wh >= 0)) return null;
  const seconds = (Date.parse(after.at) - Date.parse(before.at)) / 1000;
  const meanWatts = seconds > 0 ? Math.round((wh / (seconds / 3600)) * 10) / 10 : null;
  // Of that energy, what would NOT have been spent had the box sat idle. The
  // machine draws its baseline whether or not a case is running, so this is the
  // number to compare against a hosted model's per-call price; `wh` is the
  // number to compare against an electricity bill.
  const rates = schedule ? blendedRate(before.at, after.at, schedule) : null;
  const idleWh =
    idleWatts != null && seconds > 0
      ? Math.round(idleWatts * (seconds / 3600) * 1000) / 1000
      : null;
  return {
    wh,
    meanWatts,
    ...(idleWatts != null ? { idleWatts } : {}),
    ...(idleWh != null ? { marginalWh: Math.round(Math.max(0, wh - idleWh) * 1000) / 1000 } : {}),
    // Time-of-use: the rate depends on when the case ran, and a case long
    // enough to cross 11pm is charged at both rates. The blend and its spans are
    // stored so the cost can be audited rather than trusted.
    ...(rates
      ? {
          rates,
          cost: Math.round((wh / 1000) * rates.effectiveRatePerKwh * 100000) / 100000,
          currency: rates.currency,
          ...(idleWh != null
            ? {
                marginalCost:
                  Math.round((Math.max(0, wh - idleWh) / 1000) * rates.effectiveRatePerKwh * 100000) / 100000,
              }
            : {}),
        }
      : {}),
    // A single flat rate, for anyone not on time-of-use. Stored with the result,
    // not applied and forgotten: rates change, and a cost with no rate beside
    // it cannot be re-read later.
    ...(ratePerKwh != null
      ? {
          ratePerKwh,
          costUsd: Math.round((wh / 1000) * ratePerKwh * 100000) / 100000,
          ...(idleWh != null
            ? {
                marginalCostUsd:
                  Math.round((Math.max(0, wh - idleWh) / 1000) * ratePerKwh * 100000) / 100000,
              }
            : {}),
        }
      : {}),
  };
}

/** Plug URL and rate schedule from the environment; absent means "do not measure". */
export const powerConfig = (env = process.env) => ({
  url: env.SHELLY_URL || "",
  ratePerKwh: env.POWER_RATE_PER_KWH ? Number(env.POWER_RATE_PER_KWH) : null,
  // Time-of-use, on by default for this box. POWER_RATE_SCHEDULE=none opts out, and
  // POWER_HOLIDAYS is a comma-separated list of YYYY-MM-DD: statutory holidays
  // bill at off-peak, and the list is configuration because it changes yearly
  // and a guessed one misprices silently.
  schedule:
    env.POWER_RATE_SCHEDULE === "none"
      ? null
      : {
          ...NS_POWER_RATES,
          holidays: (env.POWER_HOLIDAYS || "").split(",").map(s => s.trim()).filter(Boolean),
        },
});
