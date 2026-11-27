// Tests for reading the price feed (Prices.lua). Run: node --test tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { luaVM } from "./harness.mjs";

const FILES = ["Core.lua", "Gathering.lua", "Trade.lua", "Ledger.lua", "Prices.lua"];
const feed = (houses) => `LootLedgerPrices = { updated = 1800000000, region = "eu", ruleset = 2, ${houses} spd = {} }`;

test("C2: a feed line in an unexpected format is ignored, not an error", () => {
  const { get } = luaVM({
    files: FILES,
    before: feed(`houses = { [113] = { name = "Horde", faction = "Horde", updated = 1800000000, listings = 10, days = 3,
                     items = { [2589] = "120,100,40", [2318] = "300,250,20,280,290" } } },`),
  });
  assert.equal(get("ns.Prices.Get(2589).hasAH"), false);
  assert.equal(get("ns.Prices.Get(2318).market"), 300);
});

test("C2: a feed without houses doesn't break House, Status or StatusText", () => {
  const { get } = luaVM({ files: FILES, before: feed("") });
  assert.equal(get("ns.Prices.House()"), null);
  assert.equal(get("ns.Prices.Status().source"), "blizzard");
  assert.match(get("ns.Prices.StatusText()"), /no auction house/);
  assert.equal(get("ns.Prices.Get(2589).hasAH"), false);
});

// Two houses; this Horde character has 10 Light Leather skinned before 3.12 (no saved price).
const TWO_HOUSES = feed(`houses = {
  [113] = { name = "Horde A", faction = "Horde", updated = 1800000000, listings = 900, days = 3, items = { [2318] = "1000,900,50,0,0" } },
  [114] = { name = "Horde B", faction = "Horde", updated = 1800000000, listings = 100, days = 3, items = { [2318] = "2000,1900,50,0,0" } },
},`) + `
  LootLedgerAccountDB = { chars = { ["-Vanish"] = { name = "Vanish", realm = "", acts = { skinning = { items = { [2318] = 10 }, days = {} } } } } }
`;

test("C3: old loot isn't priced from a guessed house; it is once the house is detected", () => {
  const { run, get } = luaVM({ files: FILES, before: TWO_HOUSES });
  assert.equal(get("select(2, ns.Prices.House())"), false); // a guess (house 113)
  assert.equal(get("ns.db.lootPricesFrom"), null);
  assert.equal(get("(ns.db.acts.skinning.lootV or {})[2318]"), null);
  run(`ns.Prices.SetHouse(114, "detected")`);                // detected at the AH: house 114
  assert.equal(get("ns.db.lootPricesFrom"), 1800000000);
  assert.equal(get("ns.db.acts.skinning.lootV[2318]"), 10 * Math.floor(2000 * 0.95));
});

test("C3: with a house already set, old loot is priced at login", () => {
  const { get } = luaVM({ files: FILES, before: TWO_HOUSES + `LootLedgerAccountDB.chars["-Vanish"].house = 113` });
  assert.equal(get("ns.db.acts.skinning.lootV[2318]"), 10 * Math.floor(1000 * 0.95));
});

// Two houses that differ in what's listed, and the AH search API stubbed: every
// SendSearchQuery is counted in QUERIES.
const DETECT = feed(`houses = {
  [113] = { name = "Horde A", faction = "Horde", listings = 900, items = { [2589] = "100,90,400,0,0", [2318] = "100,90,50,0,0" } },
  [114] = { name = "Horde B", faction = "Horde", listings = 100, items = { [2589] = "100,90,60,0,0", [2318] = "100,90,900,0,0" } },
},`) + `
  Enum = { AuctionHouseSortOrder = { Price = 0 } }
  QUERIES = 0
  C_AuctionHouse.MakeItemKey = function(id) return { itemID = id } end
  C_AuctionHouse.SendSearchQuery = function() QUERIES = QUERIES + 1 end
  C_AuctionHouse.GetCommoditySearchResultsQuantity = function() return 0 end
  C_AuctionHouse.GetCommoditySearchResultInfo = function() return nil end
`;

test("C4: closing and reopening the AH quickly runs one probe chain, not two", () => {
  const { run, get } = luaVM({ files: [...FILES, "HouseDetect.lua"], before: DETECT });
  run(`FIRE("AUCTION_HOUSE_SHOW"); ADVANCE(0.5)
       FIRE("AUCTION_HOUSE_CLOSED"); ADVANCE(0.2)
       FIRE("AUCTION_HOUSE_SHOW"); ADVANCE(1.6)`);
  assert.equal(get("QUERIES"), 1);
});

test("C4: closing the AH before the first probe stops detection", () => {
  const { run, get } = luaVM({ files: [...FILES, "HouseDetect.lua"], before: DETECT });
  run(`FIRE("AUCTION_HOUSE_SHOW"); ADVANCE(0.5)
       FIRE("AUCTION_HOUSE_CLOSED"); ADVANCE(30)`);
  assert.equal(get("QUERIES"), 0);
});

// The character's detected house (113) is missing from this hour's feed; only house 114 is there.
const MISSING = `LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."; LootLedgerPrices = { updated = NOW, houses = {
  [114] = { name = "Horde Other", faction = "Horde", updated = NOW, listings = 9000, days = 5, items = { [2318] = "99999,90000,500,0,0" } },
} }`;
function missingHouse() {
  const vm = luaVM({ files: FILES, login: false, before: MISSING });
  vm.run(`ITEMS[2318] = { name = "Light Leather", sell = 15 }; LootLedgerAccountDB = { chars = { ["-Vanish"] = { house = 113, houseSource = "detected", lootPricesFrom = 1 } } }; FIRE("PLAYER_LOGIN")`);
  return vm;
}

test("C5: a house missing from this hour's feed is kept, with no prices, not swapped for another house", () => {
  const vm = missingHouse();
  vm.run(`h, conf, how = ns.Prices.House()`);
  assert.equal(vm.get("h"), 113);
  assert.equal(vm.get("how"), "detected");
  assert.equal(vm.get("ns.Prices.Get(2318).hasAH"), false);
});

test("C5: loot gathered meanwhile isn't locked to another house's price", () => {
  const vm = missingHouse();
  vm.run(`FIRE("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 8613); FIRE("LOOT_READY"); FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(2318) .. "x2.")`);
  assert.equal(vm.get("ns.db.acts.skinning.items[2318]"), 2);
  assert.equal(vm.get("ns.db.acts.skinning.lootV[2318]"), null);
});

test("C5: loot is not locked to a guessed house's price either", () => {
  const vm = luaVM({ files: FILES, login: false, before: MISSING });
  vm.run(`ITEMS[2318] = { name = "Light Leather", sell = 15 }; LootLedgerAccountDB = { chars = { ["-Vanish"] = {} } }; FIRE("PLAYER_LOGIN")`);
  vm.run(`h, conf, how = ns.Prices.House()`);
  assert.equal(vm.get("how"), "guess");
  vm.run(`FIRE("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 8613); FIRE("LOOT_READY"); FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(2318) .. "x2.")`);
  assert.equal(vm.get("ns.db.acts.skinning.items[2318]"), 2);
  assert.equal(vm.get("ns.db.acts.skinning.lootV[2318]"), null);
});
