// Tests for the inventory scan (Inventory.lua). Run: node --test tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { luaVM } from "./harness.mjs";

const FILES = ["Core.lua", "Gathering.lua", "Trade.lua", "Ledger.lua", "Prices.lua", "Inventory.lua"];

// A current client: 4 bags + a reagent bag (5), the bank (-1), old bank bag slots
// 5..11, and character bank tabs that reuse IDs 6..11.
const CLIENT = `
  NUM_BAG_SLOTS, NUM_REAGENTBAG_SLOTS, NUM_BANKBAGSLOTS, BANK_CONTAINER = 4, 1, 7, -1
  Enum = { BagIndex = {} }
  for i = 1, 6 do Enum.BagIndex["CharacterBankTab_" .. i] = 5 + i end
  C_Container.GetContainerNumSlots = function(b) return BAGS[b] and 4 or 0 end
  ITEMS[2589] = { name = "Linen Cloth", sell = 13 }
  ITEMS[2318] = { name = "Light Leather", sell = 15 }
  ITEMS[2319] = { name = "Medium Leather", sell = 25 }
  BAGS[0]  = { [1] = { id = 2589, count = 10 } }   -- backpack
  BAGS[5]  = { [1] = { id = 2318, count = 20 } }   -- reagent bag
  BAGS[-1] = { [1] = { id = 2589, count = 3 } }    -- bank
  BAGS[6]  = { [2] = { id = 2319, count = 7 } }    -- first bank tab / bank bag
`;

test("bank scan counts every container once, and not the reagent bag", () => {
  const { run, get } = luaVM({ files: FILES, before: CLIENT });
  run(`FIRE("BANKFRAME_OPENED")`);
  assert.equal(get("ns.db.inv.bags[2589]"), 10);
  assert.equal(get("ns.db.inv.bags[2318]"), 20);
  assert.equal(get("ns.db.inv.bank[2589]"), 3);
  assert.equal(get("ns.db.inv.bank[2318]"), null, "reagent bag items are in bags, not also in the bank");
  assert.equal(get("ns.db.inv.bank[2319]"), 7, "a bank tab is counted once");
  assert.equal(get("ns.Inventory.Count(ns.db, 2318)"), 20);
});
