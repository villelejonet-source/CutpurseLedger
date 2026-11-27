// node --test poller/weekhours.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { hourOfWeek, marketIndex, recordIndex, backfillIndex, hourProfile, encodeWeekHours } from "./weekhours.mjs";

const HOUR = 3600e3;
const START = Date.parse("2026-10-05T00:23:00Z"); // a Monday, at snapshot time

function prng(seed) {
  let a = seed;
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return (((t ^ (t >>> 14)) >>> 0) / 4294967296) * 2 - 1;
  };
}

// Friday 18:00-23:59 UTC +10%, Tuesday 04:00-09:59 -6%, otherwise 0.
const FRIDAY_EVENING = (b) => (b >= 4 * 24 + 18 && b <= 4 * 24 + 23 ? 0.1 : b >= 24 + 4 && b <= 24 + 9 ? -0.06 : 0);

// Hourly index for `weeks` weeks: pattern(hourOfWeek) + drift per hour + noise.
function index(weeks, pattern, { noise = 0.02, drift = 0, seed = 7, skip = () => false } = {}) {
  const r = prng(seed);
  const out = [];
  for (let i = 0; i < weeks * 168; i++) {
    const t = START + i * HOUR;
    if (skip(i)) continue;
    out.push({ t, v: pattern(hourOfWeek(t)) + drift * i + noise * r() });
  }
  return out;
}

test("hourOfWeek is Monday 00:00 UTC based", () => {
  assert.equal(hourOfWeek(Date.parse("2026-10-05T00:23:00Z")), 0);
  assert.equal(hourOfWeek(Date.parse("2026-10-09T19:23:00Z")), 4 * 24 + 19); // Friday 19:00
  assert.equal(hourOfWeek(Date.parse("2026-10-11T23:59:00Z")), 167);
});

test("finds a Friday-evening high and a Tuesday-morning low after 3 weeks", () => {
  const p = hourProfile(index(3, FRIDAY_EVENING));
  assert.ok(p.reliable, JSON.stringify({ weeks: p.weeks, spread: p.spread, consistency: p.consistency }));
  assert.ok(p.best >= 4 * 24 + 18 && p.best <= 4 * 24 + 23, `best hour ${p.best}`);
  assert.ok(p.worst >= 24 + 4 && p.worst <= 24 + 9, `worst hour ${p.worst}`);
  assert.ok(p.pct[p.best] > 0.05 && p.pct[p.worst] < -0.02);
});

test("the same pattern on a market falling all the time", () => {
  const p = hourProfile(index(3, FRIDAY_EVENING, { drift: -0.0015 })); // about -3.5% a day
  assert.ok(p.reliable);
  assert.ok(p.best >= 4 * 24 + 18 && p.best <= 4 * 24 + 23, `best hour ${p.best}`);
});

test("missed hours (a broken chain) are fine", () => {
  const p = hourProfile(index(3, FRIDAY_EVENING, { skip: (i) => i % 17 === 0 }));
  assert.ok(p.reliable);
});

test("one week is never enough", () => {
  assert.ok(!hourProfile(index(1, FRIDAY_EVENING)).reliable);
  assert.ok(!hourProfile(index(1.5, FRIDAY_EVENING)).reliable);
});

test("noise alone rarely counts as a pattern (under 5% of 100 series)", () => {
  let flagged = 0;
  for (let seed = 1; seed <= 100; seed++) if (hourProfile(index(4, () => 0, { noise: 0.04, seed })).reliable) flagged++;
  assert.ok(flagged < 5, `${flagged} of 100 flagged`);
});

test("marketIndex: median of each liquid item's price against its previous days", () => {
  const history = { days: {
    "2026-10-04": { 1: [1000 * 24, 24, 0, 0], 2: [500 * 24, 24, 0, 0] },
    "2026-10-05": { 1: [9e9, 1, 0, 0] }, // today: not part of the reference
  } };
  const items = {};
  for (let id = 1; id <= 40; id++) items[id] = { qty: 50, market: 1100 };
  items[2] = { qty: 50, market: 550 };
  for (let id = 3; id <= 40; id++) history.days["2026-10-04"][id] = [1000 * 24, 24, 0, 0];
  items[41] = { qty: 5, market: 99999 }; // too few listed: ignored
  const v = marketIndex(history, items, Date.parse("2026-10-05T12:00:00Z"));
  assert.ok(Math.abs(v - Math.log(1.1)) < 1e-9, `index ${v}`);
  assert.equal(marketIndex({ days: {} }, items, Date.parse("2026-10-05T12:00:00Z")), null, "no previous days");
});

test("recordIndex skips a snapshot it already has, and keeps 10 weeks", () => {
  const h = {};
  recordIndex(h, 1000, 0.01, 5);
  recordIndex(h, 1000, 0.02, 5);
  assert.equal(h.index.length, 1);
  recordIndex(h, 1000 + 71 * 86400e3, 0.03, null);
  assert.deepEqual(h.index.map((x) => x.v), [0.03]);
  assert.equal(h.index[0].g, undefined);
});

test("backfillIndex starts from the hourly records already kept", () => {
  const days = { "2026-10-04": {} };
  const q = {};
  for (let id = 1; id <= 40; id++) { days["2026-10-04"][id] = [1000 * 24, 24, 0, 0]; q[id] = [50, 1050]; }
  const t = Date.parse("2026-10-05T10:23:00Z");
  const h = { days, hours: [{ t: t + HOUR, q, s: { 1: [2, 1, 3000] }, diff: true, h: 1 }, { t, q, s: {}, diff: false }] };
  backfillIndex(h);
  assert.equal(h.index.length, 2);
  assert.ok(h.index[0].t < h.index[1].t);
  assert.equal(h.index[1].g, 3000);
});

test("encodeWeekHours: 168 values, weeks, reliable, since", () => {
  const p = hourProfile(index(3, FRIDAY_EVENING));
  const parts = encodeWeekHours(p).split(";");
  assert.equal(parts[0].split(",").length, 168);
  assert.equal(parts[2], "1");
  assert.equal(Number(parts[3]), Math.floor(START / 1000));
  assert.equal(encodeWeekHours(hourProfile([])), ",".repeat(167) + ";0;0;");
});
