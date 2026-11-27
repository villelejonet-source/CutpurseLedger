// Tests for the advisor's sell/hold advice when a price is below normal (Advisor.Decide):
// a dip with steady demand is held, a drop with demand gone is sold, and a sudden
// crash with no sales data to explain it says "check the AH" instead of "wait".
import { test } from "node:test";
import assert from "node:assert/strict";
import { luaVM } from "./harness.mjs";

const FILES = ["Core.lua", "Gathering.lua", "Trade.lua", "Ledger.lua", "Prices.lua", "Inventory.lua", "Advisor.lua"];
const ID = 2318;
const NORMAL = 1000; // recent normal price (the history's baseline), copper

// One house in the feed with Light Leather at `market` now, 300 listed, a flat trend,
// daily prices `daily` (oldest first), and optionally sales / a cooling list.
function feed({ market, daily = [1000, 1000, 1000, 1000, 1000], sales, cooling = false }) {
  const hist = `d=${daily.map((v) => v.toString(36)).join(",")};t=0,${NORMAL.toString(36)},,`;
  const trending = cooling
    ? `trending = { ready = true, hoursOfData = 24, baselineDays = 5, cooling = { "${ID},20,10,100,,,6,1" } },`
    : "";
  return `
    LootLedgerPrices = { updated = NOW, spd = {}, houses = {
      [113] = { name = "Horde", faction = "Horde", updated = NOW, listings = 900, dayLabels = {},
                items = { [${ID}] = "${market},${market},300,0,0" },
                hist = { [${ID}] = "${hist}" },
                sales = { ${sales ? `[${ID}] = "${sales}"` : ""} },
                ${trending} },
    } }
    ITEMS[${ID}] = { name = "Light Leather", sell = 5 }
    LootLedgerAccountDB = { items = { [${ID}] = { name = "Light Leather", quality = 1 } },
      chars = { ["-Vanish"] = { name = "Vanish", realm = "", house = 113 } } }
  `;
}
const decide = (opts) => {
  const { get } = luaVM({ files: FILES, before: feed(opts) });
  return { action: get(`ns.Advisor.Decide(${ID}).action`), reason: get(`ns.Advisor.Decide(${ID}).reason`) };
};

test("price down and sales down: sell, demand dropped (not 'wait')", () => {
  const d = decide({ market: 600, sales: "10,100,5" }); // 10 bought in 24h, normally 100
  assert.equal(d.action, "SELL");
  assert.match(d.reason, /demand dropped \(10 sold in 24h, normally 100\)/);
});

test("price down and on the Cooling off list: sell", () => {
  const d = decide({ market: 600, cooling: true });
  assert.equal(d.action, "SELL");
  assert.match(d.reason, /demand dropped/);
});

test("price down with demand steady: a dip, hold", () => {
  const d = decide({ market: 850, sales: "95,100,30" });
  assert.equal(d.action, "HOLD");
  assert.match(d.reason, /demand steady: a dip/);
});

test("a sudden crash without sales data: check the AH, don't wait", () => {
  const d = decide({ market: 600 }); // 40% below normal, and below the last two days
  assert.equal(d.action, "CRASH");
  assert.match(d.reason, /dropped 40% since yesterday/);
});

test("steady demand wins over a crash: still a dip", () => {
  const d = decide({ market: 600, sales: "100,100,40" });
  assert.equal(d.action, "HOLD");
});

test("below normal for days already (not a crash today), no sales data: hold as before", () => {
  const d = decide({ market: 850, daily: [1000, 1000, 1000, 860, 850] });
  assert.equal(d.action, "HOLD");
  assert.match(d.reason, /vs normal, wait$/);
});

test("too few normal sales to tell: demand unknown", () => {
  const d = decide({ market: 850, sales: "0,3,0" }); // normally 3 a day: not enough to judge
  assert.equal(d.action, "HOLD");
  assert.match(d.reason, /vs normal, wait$/);
});

// ---------------------------------------------------------------------------
// Time of week: an item's weekday pattern, or the whole house's hour-of-week pattern
// ---------------------------------------------------------------------------
const TUE = Date.parse("2026-12-01T10:30:00Z") / 1000; // a Tuesday
const SAT = Date.parse("2026-12-05T10:30:00Z") / 1000;
// Mon..Sun vs the week: Tuesday -8%, Saturday +10%. 3 weeks, 100% consistent, reliable.
const WEEKDAYS = "p=-60,-80,-40,0,50,100,30,3,100,1";
// Whole house: Friday 18:00-20:59 UTC +15%, everything else 0.
const FRIDAY = Array.from({ length: 168 }, (_, b) => (b >= 4 * 24 + 18 && b <= 4 * 24 + 20 ? 150 : 0)).join(",");

function timed({ market, now, weekdays = false, house = false, trend = 0 }) {
  const hist = `d=${[1000, 1000, 1000, 1000, 1000].map((v) => v.toString(36)).join(",")};` +
    (weekdays ? WEEKDAYS + ";" : "") + `t=${trend},${NORMAL.toString(36)},,`;
  const before = `
    NOW = ${now}
    LootLedgerPrices = { updated = NOW, spd = {}, houses = {
      [113] = { name = "Horde", faction = "Horde", updated = NOW, listings = 900, dayLabels = {},
                ${house ? `week = "${FRIDAY};3;1;1790000000",` : `week = "${",".repeat(167)};0;0;",`}
                items = { [${ID}] = "${market},${market},300,0,0" },
                hist = { [${ID}] = "${hist}" }, sales = {} },
    } }
    ITEMS[${ID}] = { name = "Light Leather", sell = 5 }
    LootLedgerAccountDB = { items = { [${ID}] = { name = "Light Leather", quality = 1 } },
      chars = { ["-Vanish"] = { name = "Vanish", realm = "", house = 113 } } }
  `;
  const { get } = luaVM({ files: FILES, before });
  return { action: get(`ns.Advisor.Decide(${ID}).action`), reason: get(`ns.Advisor.Decide(${ID}).reason`) };
}

test("weekly pattern: a normal Tuesday price is held for Saturday, not listed now", () => {
  const d = timed({ market: 920, now: TUE, weekdays: true }); // Tuesday's usual price
  assert.equal(d.action, "HOLD");
  assert.equal(d.reason, "Normal price for now; list Sat, usually +20% then");
});

test("weekly pattern: Saturday at Saturday's usual price is the time to sell (not a spike)", () => {
  const d = timed({ market: 1100, now: SAT, weekdays: true });
  assert.equal(d.action, "SELL");
  assert.equal(d.reason, "Best time of the week, usually +10% vs the week");
});

test("weekly pattern: a Tuesday low is not called a dip, a real spike on Tuesday is still sold", () => {
  assert.doesNotMatch(timed({ market: 920, now: TUE, weekdays: true }).reason, /vs normal, wait/);
  const d = timed({ market: 1300, now: TUE, weekdays: true }); // +41% vs a usual Tuesday
  assert.equal(d.action, "SELL");
  assert.match(d.reason, /^\+41% vs normal/);
});

test("weekly pattern: a falling item is still sold on Tuesday", () => {
  const d = timed({ market: 920, now: TUE, weekdays: true, trend: -20 });
  assert.equal(d.action, "SELL");
  assert.match(d.reason, /^falling 2%\/day/);
});

test("without any weekly pattern the advice is as before", () => {
  assert.equal(timed({ market: 1000, now: TUE }).reason, "Normal price");
  assert.equal(timed({ market: 1100, now: SAT }).action, "SELL"); // +10% vs normal
});

test("whole-house pattern: an item without its own waits for Friday evening", () => {
  const d = timed({ market: 1000, now: TUE, house: true });
  assert.equal(d.action, "HOLD");
  assert.match(d.reason, /^Normal price for now; list Fri \d\d:00, usually \+15% then \(whole AH\)$/);
});

test("whole-house pattern: too little to gain on a cheap item, list now", () => {
  const d = timed({ market: 500, now: TUE, house: true }); // 15% of 5 silver is under 1 silver
  assert.notEqual(d.action, "HOLD");
});

test("item pattern plus house pattern: the item's best day at the house's best hour", () => {
  // The house's best hours are on Friday, not Saturday: Saturday's best hour is just its first.
  const d = timed({ market: 920, now: TUE, weekdays: true, house: true });
  assert.match(d.reason, /list Sat \d\d:00, usually \+20% then$/);
});
