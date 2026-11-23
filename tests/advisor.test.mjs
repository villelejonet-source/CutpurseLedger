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
  assert.equal(d.action, "LIST");
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
