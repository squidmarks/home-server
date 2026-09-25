// Time-of-use electricity pricing, as data.
//
// A rate schedule is not a constant, and treating it as one is wrong in two
// directions at once: a case run at 3am costs half what the same case costs at
// 9am, and a case that straddles 11pm is charged at both rates. So the schedule
// is described here and evaluated against the wall clock in the RATE SCHEDULE's own
// timezone -- not the server's, which is UTC and would shift every boundary by
// three or four hours depending on the season.
//
// Currency travels with the rate. Nova Scotia Power bills in Canadian cents;
// the hosted models we compare against bill in US dollars. A number that does
// not say which it is invites a 35% error into exactly the comparison this
// exists to make.

/** Nova Scotia Power time-of-varying pricing, as published. Rates in CAD ¢/kWh. */
export const NS_POWER_RATES = {
  name: "ns-power-tou",
  timezone: "America/Halifax",
  currency: "CAD",
  // Winter is December, January, February; everything else is non-winter.
  winterMonths: [12, 1, 2],
  rates: { onPeak: 25.188, midPeak: 20.263, offPeak: 12.436 },
  // Hours are [from, to) in local time; a window that wraps midnight is split.
  winterWeekday: [
    [7, 12, "onPeak"],
    [12, 16, "midPeak"],
    [16, 23, "onPeak"],
    [23, 24, "offPeak"],
    [0, 7, "offPeak"],
  ],
  nonWinterWeekday: [
    [7, 23, "midPeak"],
    [23, 24, "offPeak"],
    [0, 7, "offPeak"],
  ],
  // Weekends and statutory holidays are off-peak around the clock.
  weekendAndHoliday: [[0, 24, "offPeak"]],
  // ISO dates (YYYY-MM-DD) treated as holidays. Empty by default: a wrong
  // holiday list silently misprices, and guessing one is worse than leaving it
  // to configuration.
  holidays: [],
};

/** Local calendar parts for an instant, in the rate schedule's timezone. */
function localParts(date, timeZone) {
  const f = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hourCycle: "h23", weekday: "short",
  });
  const p = Object.fromEntries(f.formatToParts(date).map(x => [x.type, x.value]));
  return {
    iso: `${p.year}-${p.month}-${p.day}`,
    month: Number(p.month),
    hour: Number(p.hour),
    minuteOfDay: Number(p.hour) * 60 + Number(p.minute),
    weekend: p.weekday === "Sat" || p.weekday === "Sun",
  };
}

/** Which window list applies to a given instant. */
function windowsFor(parts, s) {
  if (parts.weekend || s.holidays.includes(parts.iso)) return s.weekendAndHoliday;
  return s.winterMonths.includes(parts.month) ? s.winterWeekday : s.nonWinterWeekday;
}

/** The period and rate in force at one instant. */
export function rateAt(date, schedule = NS_POWER_RATES) {
  const parts = localParts(date, schedule.timezone);
  const hit = windowsFor(parts, schedule).find(
    ([from, to]) => parts.hour >= from && parts.hour < to,
  );
  const period = hit ? hit[2] : "offPeak";
  return { period, ratePerKwh: schedule.rates[period] / 100, currency: schedule.currency };
}

/**
 * The rate for an interval, blended by how long it spent in each period.
 *
 * Energy is apportioned by TIME, which assumes the draw was roughly level
 * across the interval. That is fair for a benchmark case -- a steady load on one
 * box -- and would not be for a spiky one. It is stated here rather than hidden
 * because the alternative, charging the whole case at whatever rate happened to
 * apply when it started, is wrong by a factor of two across the 11pm boundary.
 *
 * `spans` is returned so a cost can be audited afterwards instead of taken on
 * trust.
 */
export function blendedRate(startIso, endIso, schedule = NS_POWER_RATES) {
  const start = Date.parse(startIso);
  const end = Date.parse(endIso);
  if (!(end > start)) return null;
  // One minute is finer than any boundary in the schedule and cheap over the
  // length of a case.
  const step = 60_000;
  const spans = new Map();
  for (let t = start; t < end; t += step) {
    const width = Math.min(step, end - t);
    const { period } = rateAt(new Date(t), schedule);
    spans.set(period, (spans.get(period) ?? 0) + width);
  }
  const total = end - start;
  const parts = [...spans.entries()].map(([period, ms]) => ({
    period,
    ms,
    seconds: Math.round(ms / 1000),
    share: Math.round((ms / total) * 1000) / 1000,
    ratePerKwh: schedule.rates[period] / 100,
  }));
  // Weight by the RAW milliseconds, not the rounded seconds. Rounding first and
  // dividing by the unrounded total made the weights fail to sum to one: a
  // 3.63 s request rounded to 4 s came out at 110% weight, and a single-period
  // blend reported a rate 10% above the rate it was blending. Invisible over a
  // case of minutes, material per request.
  const effective = parts.reduce((a, p) => a + p.ratePerKwh * (p.ms / total), 0);
  return {
    schedule: schedule.name,
    currency: schedule.currency,
    effectiveRatePerKwh: Math.round(effective * 100000) / 100000,
    spans: parts.sort((a, b) => b.seconds - a.seconds),
  };
}
