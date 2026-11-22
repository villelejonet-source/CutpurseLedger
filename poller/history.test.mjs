// node --test poller/history.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { addSnapshot, archiveOldDays, allDays, monthKeys, monthlyFor, seriesFor, encodeHistory, labels } from "./history.mjs";

const DAY = 86400e3;
const START = Date.parse("2026-07-01T12:00:00Z");

function build(days) {
  const h = { days: {}, months: {} };
  for (let i = 0; i < days; i++) {
    const t = START + i * DAY;
    // two snapshots a day: 100 and 120 -> daily market 110 (item 1)
    addSnapshot(h, { 1: { market: 100, min: 90, qty: 10 } }, t);
    addSnapshot(h, { 1: { market: 120, min: 95, qty: 30 } }, t);
  }
  return h;
}

test("addSnapshot sums hourly market and quantity, keeps the lowest min", () => {
  const h = build(1);
  assert.deepEqual(Object.values(h.days)[0][1], [220, 2, 90, 40]);
  const s = seriesFor(h, allDays(h, START), "1");
  assert.equal(s[0].market, 110);
  assert.equal(s[0].qty, 20);
});

test("old days fold into monthly averages and are removed", () => {
  const h = build(200);
  const now = START + 199 * DAY;
  archiveOldDays(h, now, 120);
  assert.ok(Object.keys(h.days).length <= 121, `kept ${Object.keys(h.days).length} days`);
  assert.ok(h.months["2026-07"], "July archived");
  assert.deepEqual(h.months["2026-07"][1], [110 * 31, 31]);
});

test("monthly series combine archive and daily window, newest 12 months", () => {
  const h = build(200);
  const now = START + 199 * DAY;
  archiveOldDays(h, now, 120);
  const days = allDays(h, now);
  const keys = monthKeys(h, days);
  assert.equal(keys[0], "2026-07");
  assert.equal(keys[keys.length - 1], "2027-01");
  const m = monthlyFor(h, days, "1", keys);
  assert.ok(m.every((v) => v === 110), `monthly ${m}`);
});

test("encodeHistory uses the monthly series it is given", () => {
  const h = build(10);
  const now = START + 9 * DAY;
  const days = allDays(h, now);
  const keys = monthKeys(h, days);
  const enc = encodeHistory(seriesFor(h, days, "1"), monthlyFor(h, days, "1", keys));
  assert.match(enc, /;m=32;/); // 110 in base 36
  assert.match(labels(days, keys), /monthLabels = \{ "2026-07" \}/);
});
