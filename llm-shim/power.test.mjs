import test from "node:test";
import assert from "node:assert/strict";
import { energyOf, powerConfig, readPlug } from "./power.mjs";

const at = s => new Date(Date.UTC(2026, 8, 25, 0, 0, s)).toISOString();

test("energy is the counter's delta, and the mean power follows from it", () => {
  // 15 minutes at a steady 300 W is 75 Wh.
  const e = energyOf({ wh: 1000, at: at(0) }, { wh: 1075, at: at(900) }, { ratePerKwh: 0.15 });
  assert.equal(e.wh, 75);
  assert.equal(e.meanWatts, 300);
  assert.equal(e.costUsd, 0.01125); // 0.075 kWh at 15c
  assert.equal(e.ratePerKwh, 0.15); // kept, so the cost can be re-read when the rates change
});

test("the idle baseline separates what the case cost from what the box costs anyway", () => {
  // The same 75 Wh, on a box that draws 46 W sitting still: 11.5 Wh of it would
  // have been spent regardless. Comparing a hosted model's per-call price against
  // the full 75 would charge local inference for the machine being switched on.
  const e = energyOf({ wh: 0, at: at(0) }, { wh: 75, at: at(900) }, { ratePerKwh: 0.15, idleWatts: 46 });
  assert.equal(e.idleWatts, 46);
  assert.equal(e.marginalWh, 63.5);
  assert.equal(e.marginalCostUsd, 0.00953);
  assert.equal(e.wh, 75); // the absolute figure is kept too; they answer different questions
});

test("a counter reset is reported as nothing, never as negative energy", () => {
  // A Shelly's total restarts at zero when its energy data is cleared. A pair of
  // readings straddling that looks like the case gave power back.
  assert.equal(energyOf({ wh: 900, at: at(0) }, { wh: 3, at: at(900) }), null);
  assert.equal(energyOf(null, { wh: 3, at: at(900) }), null);
  assert.equal(energyOf({ wh: 1, at: at(0) }, null), null);
});

test("a plug that cannot be reached stops no benchmark", async () => {
  assert.equal(await readPlug(""), null);
  assert.equal(await readPlug("http://192.0.2.1", { fetchImpl: async () => { throw new Error("EHOSTUNREACH"); } }), null);
  assert.equal(await readPlug("http://p", { fetchImpl: async () => ({ ok: false }) }), null);
  // A reply without the counter is not a reading.
  assert.equal(await readPlug("http://p", { fetchImpl: async () => ({ ok: true, json: async () => ({ apower: 46 }) }) }), null);
});

test("a real Gen4 reply is read for its counter and its instantaneous draw", async () => {
  const body = { id: 0, apower: 46.0, voltage: 119.0, aenergy: { total: 6.55, by_minute: [714.563] } };
  const r = await readPlug("http://192.168.68.112/", { fetchImpl: async () => ({ ok: true, json: async () => body }) });
  assert.equal(r.wh, 6.55);
  assert.equal(r.watts, 46);
  assert.match(r.at, /^\d{4}-/);
});

test("no plug configured means no measurement, not a zero", () => {
  const bare = powerConfig({});
  assert.equal(bare.url, "");
  assert.equal(bare.ratePerKwh, null);
  const set = powerConfig({ SHELLY_URL: "http://p", POWER_RATE_PER_KWH: "0.21" });
  assert.equal(set.url, "http://p");
  assert.equal(set.ratePerKwh, 0.21);
});

test("a time-of-use case is priced by when it ran, in the schedule's currency", async () => {
  const { powerConfig } = await import("./power.mjs");
  // 75 Wh over 30 minutes from 22:50 AST, straddling the 11pm drop to off-peak.
  const e = energyOf(
    { wh: 0, at: "2026-01-16T02:50:00Z" },
    { wh: 75, at: "2026-01-16T03:20:00Z" },
    { schedule: powerConfig({}).schedule, idleWatts: 46 },
  );
  assert.equal(e.currency, "CAD"); // NOT usd: hosted models bill in USD and the
  assert.equal(e.rates.effectiveRatePerKwh, 0.16687); // two must not be added up
  assert.equal(e.cost, 0.01252);
  // The spans are kept so the blend can be checked rather than trusted.
  assert.deepEqual(e.rates.spans.map(s => s.period).sort(), ["offPeak", "onPeak"]);
  // 46 W for half an hour is 23 Wh the box would have drawn anyway, leaving 52.
  assert.equal(e.marginalWh, 52);
  assert.equal(e.marginalCost, 0.00868);
});

test("opting out of time-of-use leaves a flat rate, or nothing", async () => {
  const { powerConfig } = await import("./power.mjs");
  assert.equal(powerConfig({ POWER_RATE_SCHEDULE: "none" }).schedule, null);
  assert.deepEqual(powerConfig({ POWER_HOLIDAYS: "2026-07-01, 2026-12-25" }).schedule.holidays,
    ["2026-07-01", "2026-12-25"]);
});
