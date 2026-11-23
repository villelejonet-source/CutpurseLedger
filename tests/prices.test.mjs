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
