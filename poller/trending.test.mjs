// node --test poller/trending.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { diffSnapshots, recordHour, TIME_LEFT } from "./sales.mjs";
import { trendingLists, encodeEntry } from "./trending.mjs";

const HOUR = 3600e3, DAY = 24 * HOUR;
const NOW = Date.parse("2026-11-30T12:00:00Z");
const { SHORT, MEDIUM, LONG } = TIME_LEFT;

// ---------------------------------------------------------------------------
// Snapshot diffs
// ---------------------------------------------------------------------------
test("a listing that's gone was bought; a smaller stack was partly bought", () => {
  const prev = { t: 0, l: [[1, 100, 20, 50, LONG], [2, 100, 10, 60, LONG]] };
  const cur = { t: HOUR, l: [[2, 100, 4, 60, LONG]] };
  const d = diffSnapshots(prev, cur).get(100);
  assert.equal(d.units, 26);
  assert.equal(d.auctions, 2);
  assert.equal(d.gold, 20 * 50 + 6 * 60);
});

test("listings about to run out count as expired, not bought", () => {
  const prev = { t: 0, l: [[1, 100, 20, 50, SHORT], [2, 100, 5, 50, MEDIUM]] };
  const cur = { t: 3 * HOUR, l: [] }; // gap over 2h: MEDIUM may have expired too
  const d = diffSnapshots(prev, cur).get(100);
  assert.equal(d.units, 0);
  assert.equal(d.expired, 25);
});

test("cancel + relist of the same stack size is not a sale", () => {
  const prev = { t: 0, l: [[1, 100, 20, 50, LONG]] };
  const cur = { t: HOUR, l: [[9, 100, 20, 45, LONG]] };
  const d = diffSnapshots(prev, cur).get(100);
  assert.equal(d.units, 0);
  assert.equal(d.relisted, 20);
});

test("snapshots too far apart are not compared", () => {
  const prev = { t: 0, l: [[1, 100, 20, 50, LONG]] };
  assert.equal(diffSnapshots(prev, { t: 13 * HOUR, l: [] }).size, 0);
});

// ---------------------------------------------------------------------------
// Trending lists, from synthetic history
// ---------------------------------------------------------------------------
// items: id -> { normal: units/day, today(hourIndex 0..23) -> [units, auctions], market, qty, marketThen, qtyThen }
function history(spec) {
  const h = { hours: [], sales: {}, salesHours: {} };
  for (let d = 7; d >= 2; d--) {
    const key = new Date(NOW - d * DAY).toISOString().slice(0, 10);
    h.sales[key] = {};
    h.salesHours[key] = 24;
    for (const [id, s] of Object.entries(spec)) h.sales[key][id] = [s.normal, Math.max(1, Math.round(s.normal / 3)), s.normal * s.market];
  }
  for (let i = 0; i < 24; i++) {
    const t = NOW - (23 - i) * HOUR;
    const s = {}, q = {};
    for (const [id, x] of Object.entries(spec)) {
      const [units, auctions] = x.today(i);
      if (units > 0) s[id] = [units, auctions, units * x.market];
      q[id] = i === 0 ? [x.qtyThen ?? x.qty, x.marketThen ?? x.market] : [x.qty, x.market];
    }
    h.hours.push({ t, s, q, diff: true });
  }
  return h;
}
const itemsOf = (spec) => Object.fromEntries(Object.entries(spec).map(([id, x]) => [id, { market: x.market, qty: x.qty }]));
const ids = (list) => list.map((e) => e.id);

const SPEC = {
  // A real surge: Runecloth-like, normally 200/day, today 600 spread over the day, many auctions.
  14047: { normal: 200, market: 500, qty: 3000, today: (i) => [25, 6] },
  // One buyer sweeping a page: same total, but almost all in one hour and few auctions.
  9187: { normal: 200, market: 2400, qty: 1800, today: (i) => (i === 20 ? [560, 3] : [2, 1]) },
  // Grey junk with a tiny market: 2/day normally, 10 today, worth almost nothing.
  4583: { normal: 2, market: 30, qty: 40, today: (i) => (i < 10 ? [1, 1] : [0, 0]) },
  // Normal item, nothing special.
  4304: { normal: 300, market: 700, qty: 5000, today: (i) => [12, 4] },
  // Price spike from 2 listings left (no volume behind it).
  8170: { normal: 50, market: 4000, marketThen: 1900, qty: 2, qtyThen: 40, today: (i) => [2, 1] },
  // A real price climb with volume.
  4306: { normal: 400, market: 760, marketThen: 600, qty: 2000, today: (i) => [20, 6] },
  // Cooling off: normally 300/day, today ~70.
  8171: { normal: 300, market: 2000, qty: 900, today: (i) => (i % 8 === 0 ? [23, 5] : [0, 0]) },
};

test("a real surge is 'selling fast'; a bulk buyout, grey junk and normal trade are not", () => {
  const { lists, ready } = trendingLists(history(SPEC), itemsOf(SPEC), NOW);
  assert.ok(ready);
  assert.ok(ids(lists.hot).includes(14047), "Runecloth surge should be hot");
  assert.ok(!ids(lists.hot).includes(9187), "a single-hour sweep is not hot");
  assert.ok(!ids(lists.hot).includes(4583), "grey junk is not hot");
  assert.ok(!ids(lists.hot).includes(4304), "normal trade is not hot");
});

test("price climbing needs volume: 2 listings left don't count, a broad rise does", () => {
  const { lists } = trendingLists(history(SPEC), itemsOf(SPEC), NOW);
  assert.ok(!ids(lists.climbing).includes(8170), "spike from 2 listings is ignored");
  assert.ok(ids(lists.climbing).includes(4306), "real climb is listed");
});

test("cooling off is found", () => {
  const { lists } = trendingLists(history(SPEC), itemsOf(SPEC), NOW);
  assert.ok(ids(lists.cooling).includes(8171));
  assert.ok(!ids(lists.cooling).includes(14047));
});

test("drying up: listings shrinking while people keep buying", () => {
  const spec = { 2318: { normal: 300, market: 900, qty: 400, qtyThen: 1200, today: (i) => [15, 5] } };
  const { lists } = trendingLists(history(spec), itemsOf(spec), NOW);
  assert.ok(ids(lists.drying).includes(2318));
});

test("one weird hour is not enough: the surge must still be going", () => {
  const spec = { 14047: { normal: 200, market: 500, qty: 3000, today: (i) => (i < 12 ? [50, 10] : [0, 0]) } };
  const { lists } = trendingLists(history(spec), itemsOf(spec), NOW);
  assert.ok(!ids(lists.hot).includes(14047), "surge that stopped 12 hours ago is not 'right now'");
});

test("nothing is listed until there is enough history", () => {
  const h = history(SPEC);
  h.sales = {}; h.salesHours = {};
  const r = trendingLists(h, itemsOf(SPEC), NOW);
  assert.equal(r.ready, false);
  assert.equal(r.lists.hot.length, 0);
});

test("recordHour keeps 30 hours and daily totals", () => {
  const h = {};
  for (let i = 0; i < 40; i++) {
    recordHour(h, NOW + i * HOUR, new Map([[5, { units: 2, auctions: 1, gold: 100 }]]), { 5: { qty: 10, market: 50 } });
  }
  assert.equal(h.hours.length, 30);
  const total = Object.values(h.sales).reduce((s, d) => s + (d[5]?.[0] ?? 0), 0);
  assert.equal(total, 80);
});

test("encodeEntry is compact and complete", () => {
  const s = encodeEntry({ id: 14047, sold24: 600, auctions24: 144, normal: 200, priceChange: 0.142, supplyChange: -0.3, hoursActive: 24, conf: 2 });
  assert.equal(s, "14047,600,144,200,142,-300,24,2");
});
