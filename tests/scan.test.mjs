// Tests for the in-game AH scan (Scan.lua) and its use in Prices.Get.
import { test } from "node:test";
import assert from "node:assert/strict";
import { luaVM } from "./harness.mjs";

const FILES = ["Core.lua", "Gathering.lua", "Trade.lua", "Ledger.lua", "Prices.lua", "Scan.lua", "Inventory.lua", "Advisor.lua"];

// The feed (an hour old) says Light Leather is 10s at house 113; the character uses 113.
// LISTINGS is what the AH returns to a full scan: { itemID, count, buyout for the stack }.
const SETUP = `
  LootLedgerPrices = { updated = NOW - 3600, spd = {}, houses = {
    [113] = { name = "Horde", faction = "Horde", updated = NOW - 3600, listings = 900,
              items = { [2318] = "1000,950,50,0,0", [2589] = "200,150,500,0,0" } },
  } }
  LootLedgerAccountDB = { chars = { ["-Vanish"] = { name = "Vanish", realm = "", house = 113, houseSource = "detected" } } }
  LISTINGS = {
    { 2318, 20, 16000 },   -- 20 at 8s each
    { 2318, 10, 9000 },    -- 10 at 9s each
    { 2319, 5, 2500 },     -- 5 Medium Leather at 5s
    { 2319, 1, 0 },        -- bid only: skipped
  }
  REPLICATE_CALLS = 0
  C_AuctionHouse.ReplicateItems = function() REPLICATE_CALLS = REPLICATE_CALLS + 1 end
  C_AuctionHouse.GetNumReplicateItems = function() return #LISTINGS end
  C_AuctionHouse.GetReplicateItemInfo = function(k)
    local l = LISTINGS[k + 1]
    return "name", nil, l[2], 1, true, 1, nil, 0, 0, l[3], 0, false, nil, "seller", nil, 0, l[1], true
  end
`;
const vm = () => {
  const v = luaVM({ files: FILES, before: SETUP });
  v.run(`ns.Scan.CHUNK = 2   -- several frames, like a real scan
         FIRE("AUCTION_HOUSE_SHOW")`);
  return v;
};
const scan = `assert(ns.Scan.Start()); FIRE("REPLICATE_ITEM_LIST_UPDATE"); ADVANCE(1)`;

test("a scan saves this house's prices and they replace the older feed's", () => {
  const { run, get } = vm();
  assert.equal(get("ns.Prices.Get(2318).market"), 1000);   // the feed, before
  run(scan);
  assert.equal(get("REPLICATE_CALLS"), 1);
  // 30 units: market = average of the cheapest 15% (5 units, all at 8s)
  assert.equal(get("ns.acc.scans[113].items[2318]"), "800,800,30");
  assert.equal(get("ns.acc.scans[113].items[2319]"), "500,500,5");
  assert.equal(get("ns.acc.scans[113].listings"), 4);
  assert.equal(get("ns.Prices.Get(2318).market"), 800);
  assert.equal(get("ns.Prices.Get(2318).auctions"), 30);
  assert.equal(get("ns.Prices.Get(2318).scanned"), get("NOW"));
  assert.equal(get("ns.Prices.Get(2318).source"), "blizzard");
});

test("items missing from the scan keep the feed's numbers; an older scan is ignored", () => {
  const { run, get } = vm();
  run(scan);
  assert.equal(get("ns.Prices.Get(2589).market"), 200);
  assert.equal(get("ns.Prices.Get(2589).scanned"), null);
  run(`ns.acc.scans[113].t = NOW - 7200; ns.Prices.ClearCache()`);   // older than the feed
  assert.equal(get("ns.Prices.Get(2318).market"), 1000);
});

test("one scan every 15 minutes; only at the AH; not while one is running", () => {
  const { run, get } = vm();
  run(scan);
  assert.equal(get("ns.Scan.Start()"), false);
  assert.match(get("PRINTED[#PRINTED]"), /every 15 minutes/);
  run(`NOW = NOW + 15 * 60`);
  run(`FIRE("AUCTION_HOUSE_CLOSED"); ADVANCE(5)`);
  assert.equal(get("ns.Scan.Start()"), false);
  assert.match(get("PRINTED[#PRINTED]"), /Open the auction house/);
  run(`FIRE("AUCTION_HOUSE_SHOW")`);
  assert.equal(get("ns.Scan.Start()"), true);
  assert.equal(get("ns.Scan.Start()"), false);
  assert.match(get("PRINTED[#PRINTED]"), /already running/);
});

test("closing the AH before the answer stops the scan; no answer times out", () => {
  const { run, get } = vm();
  run(`assert(ns.Scan.Start()); FIRE("AUCTION_HOUSE_CLOSED"); FIRE("REPLICATE_ITEM_LIST_UPDATE"); ADVANCE(1)`);
  assert.equal(get("ns.acc.scans"), null);
  assert.equal(get("ns.Scan.Running()"), false);
  const v = vm();
  v.run(`NOW = NOW + 3600; assert(ns.Scan.Start()); ADVANCE(61)`);
  assert.equal(v.get("ns.Scan.Running()"), false);
  assert.match(v.get("PRINTED[#PRINTED]"), /didn't answer/);
});

test("each day's last scan is kept for 14 days", () => {
  const { run, get } = vm();
  run(`ns.acc.scanDays = { [113] = { [ns.DayKey(20)] = { [2318] = 1 }, [ns.DayKey(3)] = { [2318] = 900 } } }`);
  run(scan);
  assert.equal(get("ns.acc.scanDays[113][ns.DayKey(20)]"), null);
  assert.equal(get("ns.acc.scanDays[113][ns.DayKey(3)][2318]"), 900);
  assert.equal(get("ns.acc.scanDays[113][ns.DayKey()][2318]"), 800);
});

test("a client without the full-scan API says so and changes nothing", () => {
  const { run, get } = vm();
  run(`C_AuctionHouse.ReplicateItems = nil`);
  assert.equal(get("ns.Scan.Start()"), false);
  assert.match(get("PRINTED[#PRINTED]"), /can't scan/);
  assert.equal(get("ns.Prices.Get(2318).market"), 1000);
});
