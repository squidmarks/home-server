import test from "node:test";
import assert from "node:assert/strict";
import { NS_POWER_RATES, blendedRate, rateAt } from "./rate-schedule.mjs";

// Halifax is UTC-4 in winter (AST) and UTC-3 in summer (ADT). Every case below
// is written as the UTC instant, because that is what a result records, and
// asserts on the LOCAL period -- which is the whole point of the module.
const at = iso => new Date(iso);

test("the schedule is read in Halifax time, not the server's UTC", () => {
  // 11:00 UTC in January is 07:00 AST: the first minute of on-peak. Read as UTC
  // it would be off-peak, and the case would be priced at half.
  assert.equal(rateAt(at("2026-01-15T11:00:00Z")).period, "onPeak");
  assert.equal(rateAt(at("2026-01-15T10:59:00Z")).period, "offPeak");
  // Summer shifts the same boundary by an hour: 10:00 UTC is 07:00 ADT.
  assert.equal(rateAt(at("2026-07-15T10:00:00Z")).period, "midPeak");
  assert.equal(rateAt(at("2026-07-15T09:59:00Z")).period, "offPeak");
});

test("winter weekdays have two on-peak blocks with mid-peak between them", () => {
  const p = iso => rateAt(at(iso)).period;
  assert.equal(p("2026-01-15T12:00:00Z"), "onPeak");  // 08:00 AST
  assert.equal(p("2026-01-15T17:00:00Z"), "midPeak"); // 13:00 AST
  assert.equal(p("2026-01-15T21:00:00Z"), "onPeak");  // 17:00 AST
  assert.equal(p("2026-01-16T04:00:00Z"), "offPeak"); // 00:00 AST
  assert.equal(rateAt(at("2026-01-15T12:00:00Z")).ratePerKwh, 0.25188);
});

test("non-winter weekdays have no on-peak at all", () => {
  const p = iso => rateAt(at(iso)).period;
  assert.equal(p("2026-06-15T12:00:00Z"), "midPeak"); // 09:00 ADT
  assert.equal(p("2026-06-15T20:00:00Z"), "midPeak"); // 17:00 ADT
  assert.equal(p("2026-06-16T03:00:00Z"), "offPeak"); // 00:00 ADT
});

test("weekends are off-peak all day, and so are configured holidays", () => {
  // 2026-01-17 is a Saturday: 09:00 AST would be on-peak on a weekday.
  assert.equal(rateAt(at("2026-01-17T13:00:00Z")).period, "offPeak");
  const withHoliday = { ...NS_POWER_RATES, holidays: ["2026-01-15"] };
  assert.equal(rateAt(at("2026-01-15T13:00:00Z"), withHoliday).period, "offPeak");
  // and without it configured, that same weekday is priced at peak
  assert.equal(rateAt(at("2026-01-15T13:00:00Z")).period, "onPeak");
});

test("a case that straddles a boundary is charged at both rates", () => {
  // 30 minutes from 22:50 AST: ten minutes on-peak, twenty off-peak.
  const r = blendedRate("2026-01-16T02:50:00Z", "2026-01-16T03:20:00Z");
  assert.equal(r.currency, "CAD");
  assert.deepEqual(r.spans.map(s => s.period).sort(), ["offPeak", "onPeak"]);
  const off = r.spans.find(s => s.period === "offPeak");
  assert.equal(off.seconds, 1200);
  // Blended: (10 x 25.188 + 20 x 12.436) / 30 = 16.687 c/kWh. Charging the whole
  // case at its starting rate would overstate it by half.
  assert.equal(r.effectiveRatePerKwh, 0.16687);
});

test("a case inside one period has one span and that period's exact rate", () => {
  const r = blendedRate("2026-07-15T06:00:00Z", "2026-07-15T06:30:00Z"); // 03:00 ADT
  assert.equal(r.spans.length, 1);
  assert.equal(r.spans[0].period, "offPeak");
  assert.equal(r.effectiveRatePerKwh, 0.12436);
  assert.equal(r.spans[0].share, 1);
});

test("an interval that did not advance prices nothing", () => {
  assert.equal(blendedRate("2026-07-15T06:00:00Z", "2026-07-15T06:00:00Z"), null);
  assert.equal(blendedRate("2026-07-15T06:30:00Z", "2026-07-15T06:00:00Z"), null);
});

test("a blend of one rate is that rate, however short the window", () => {
  // Rounding the span to whole seconds and dividing by the unrounded total made
  // the weights miss one: 3.63 s became 4 s over 3.63 s, a 10% overstatement,
  // and a single-period "blend" came out above the only rate in it.
  const r = blendedRate("2026-07-15T06:00:00.000Z", "2026-07-15T06:00:03.632Z"); // 03:00 ADT
  assert.equal(r.spans.length, 1);
  assert.equal(r.spans[0].period, "offPeak");
  assert.equal(r.effectiveRatePerKwh, 0.12436); // exactly the off-peak rate
  // and the shares still sum to one
  assert.equal(r.spans.reduce((a, s) => a + s.share, 0), 1);
});
