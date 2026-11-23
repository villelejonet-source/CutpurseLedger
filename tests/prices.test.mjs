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
