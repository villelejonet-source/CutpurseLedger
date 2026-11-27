// Tests for gathering detection (Gathering.lua): which loot counts as pickpocket,
// skinning, ... with and without fast-loot addons. Run: node --test tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { luaVM } from "./harness.mjs";

const BEFORE = `
  SPELLS = { [921] = "Pick Pocket", [8613] = "Skinning", [2575] = "Mining", [2366] = "Herb Gathering", [1752] = "Sinister Strike", [7620] = "Fishing" }
  C_Spell = { GetSpellInfo = function(id) return SPELLS[id] and { name = SPELLS[id] } end }
  LOOT_ITEM_SELF = "You receive loot: %s."
  LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
  ITEMS[5428] = { name = "An Exotic Cookbook", sell = 25 }
  ITEMS[2318] = { name = "Light Leather", sell = 15 }
  ITEMS[4306] = { name = "Silk Cloth", sell = 150 }
  LOOT_MONEY_SPLIT = "Your share of the loot is %s."
  YOU_LOOT_MONEY = "You loot %s"
  LOOT_SLOTS = {}   -- item IDs in the open loot window
  GetNumLootItems = function() return #LOOT_SLOTS end
  GetLootSlotLink = function(i) return LOOT_SLOTS[i] and LINK(LOOT_SLOTS[i]) end
`;
const vm = () => luaVM({ before: BEFORE });
const pp = (field) => `ns.Gathering.Bucket("pickpocket").${field}`;
const cast = (id) => `FIRE("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-guid", ${id})`;

test("normal looting: cast, loot window, coins and an item", () => {
  const { run, get } = vm();
  run(`${cast(921)}
       FIRE("LOOT_READY"); FIRE("LOOT_OPENED")
       GAIN(57)
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(5428) .. ".")
       FIRE("LOOT_CLOSED")
       ADVANCE(5)`);
  assert.equal(get(pp("copper")), 57);
  assert.equal(get(`${pp("items")}[5428]`), 1);
  assert.equal(get(pp("count")), 1);
  assert.equal(get("LOG(1)"), "pickpocket 57");
});

test("fast loot: coins arrive before the loot window opens", () => {
  const { run, get } = vm();
  // A fast-loot addon loots on LOOT_READY: money and the item land, then the window
  // opens and closes in the same moment.
  run(`${cast(921)}
       FIRE("LOOT_READY")
       GAIN(83)
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(5428) .. ".")
       FIRE("LOOT_OPENED"); FIRE("LOOT_CLOSED")
       ADVANCE(5)`);
  assert.equal(get(pp("copper")), 83);
  assert.equal(get(`${pp("items")}[5428]`), 1);
  assert.equal(get(pp("count")), 1);
  assert.equal(get("LOG(1)"), "pickpocket 83");
});

test("no loot window of your own: nothing after the cast counts as pickpocket", () => {
  const { run, get } = vm();
  run(`${cast(921)}
       ADVANCE(0.3); GAIN(40)
       ADVANCE(0.3); FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(5428) .. ".")
       ADVANCE(5)`);
  assert.equal(get(pp("copper")), 0);
  assert.equal(get(`${pp("items")}[5428]`), null);
  assert.equal(get(pp("empty")), 1);
});

test("loot window event before the cast event still counts", () => {
  const { run, get } = vm();
  run(`LOOT_SLOTS = { 5428 }
       FIRE("LOOT_READY")
       ${cast(921)}
       GAIN(25)
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(5428) .. ".")
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(pp("copper")), 25);
  assert.equal(get(`${pp("items")}[5428]`), 1);
});

test("party: shared coins after your pickpocket coins are taken back", () => {
  const { run, get } = vm();
  run(`${cast(921)}
       FIRE("LOOT_READY"); GAIN(50); FIRE("CHAT_MSG_MONEY", "You loot 50 Copper")
       FIRE("LOOT_CLOSED")
       ADVANCE(0.5)
       GAIN(1200); FIRE("CHAT_MSG_MONEY", "Your share of the loot is 12 Silver.")
       ADVANCE(5)`);
  assert.equal(get(pp("copper")), 50);
  assert.equal(get("LOG(1)"), "loot 1200");
  assert.equal(get("LOG(2)"), "pickpocket 50");
  assert.equal(get("ns.db.ledger.days[ns.DayKey()].pickpocket.inc"), 50);
});

test("party: a shared-loot message before its coins keeps them out", () => {
  const { run, get } = vm();
  run(`${cast(921)}
       FIRE("LOOT_READY")
       FIRE("CHAT_MSG_MONEY", "Your share of the loot is 12 Silver.")
       GAIN(1200)
       GAIN(30)
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(pp("copper")), 30);
  assert.equal(get("LOG(2)"), "loot 1200");
});

test("party: an item won in a roll isn't counted as pickpocket", () => {
  const { run, get } = vm();
  run(`LOOT_SLOTS = { 5428 }
       ${cast(921)}
       FIRE("LOOT_READY")
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(5428) .. ".")
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(4306) .. ".")
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(`${pp("items")}[5428]`), 1);
  assert.equal(get(`${pp("items")}[4306]`), null);
});

test("party: other players looting doesn't count", () => {
  const { run, get } = vm();
  run(`LOOT_SLOTS = { 5428 }
       ${cast(921)}
       FIRE("LOOT_READY")
       FIRE("CHAT_MSG_LOOT", "Bob receives loot: " .. LINK(4306) .. ".")
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(`${pp("items")}[4306]`), null);
});

test("an empty pocket counts as empty; later mob loot isn't pickpocket", () => {
  const { run, get } = vm();
  run(`${cast(921)}
       ADVANCE(5)
       FIRE("LOOT_READY"); FIRE("LOOT_OPENED"); GAIN(120); FIRE("LOOT_CLOSED")
       ADVANCE(5)`);
  assert.equal(get(pp("empty")), 1);
  assert.equal(get(pp("count")), 0);
  assert.equal(get(pp("copper")), 0);
  assert.equal(get("LOG(1)"), "loot 120");
});

test("a loot window kept open keeps crediting past the wait", () => {
  const { run, get } = vm();
  run(`${cast(8613)}
       FIRE("LOOT_READY"); FIRE("LOOT_OPENED")
       ADVANCE(6)   -- player looks at the window for a while
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(2318) .. "x2.")
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(`ns.Gathering.Bucket("skinning").items[2318]`), 2);
  assert.equal(get(`ns.Gathering.Bucket("skinning").count`), 1);
});

test("other spells don't start gathering", () => {
  const { run, get } = vm();
  run(`${cast(1752)}
       FIRE("LOOT_READY"); GAIN(30); FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(pp("count")), 0);
  assert.notEqual(get("LOG(1)"), "pickpocket 30");
});

test("detection works by spell ID even if the spell name isn't known", () => {
  const { run, get } = vm();
  run(`SPELLS[921] = nil
       ${cast(921)}
       FIRE("LOOT_READY"); GAIN(10); FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(pp("copper")), 10);
});

test("two pockets in a row are counted separately", () => {
  const { run, get } = vm();
  run(`${cast(921)}
       FIRE("LOOT_READY"); GAIN(20); FIRE("LOOT_CLOSED")
       ADVANCE(0.5)
       ${cast(921)}
       FIRE("LOOT_READY"); GAIN(30); FIRE("LOOT_CLOSED")
       ADVANCE(5)`);
  assert.equal(get(pp("count")), 2);
  assert.equal(get(pp("copper")), 50);
  assert.equal(get(pp("best")), 30);
});

// Fishing: the catch comes up to ~30 s after the cast, and only fishing loot counts.
const FISH = `ITEMS[6303] = { name = "Raw Slitherskin Mackerel", sell = 1 }
  FISHING_LOOT = false
  IsFishingLoot = function() return FISHING_LOOT end`;
const fish = (field) => `ns.Gathering.Bucket("fishing").${field}`;

test("fishing: a catch 20 seconds after the cast counts", () => {
  const { run, get } = vm();
  run(`${FISH}
       ${cast(7620)}
       ADVANCE(20)
       LOOT_SLOTS = { 6303 }; FISHING_LOOT = true
       FIRE("UNIT_SPELLCAST_CHANNEL_STOP", "player", "cast-guid", 7620)
       FIRE("LOOT_READY"); FIRE("LOOT_OPENED")
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(6303) .. ".")
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(`${fish("items")}[6303]`), 1);
  assert.equal(get(fish("count")), 1);
  assert.equal(get(fish("empty")), 0);
});

test("fishing: no bite counts as got away, without waiting the full 30 seconds", () => {
  const { run, get } = vm();
  run(`${FISH}
       ${cast(7620)}
       ADVANCE(21); FIRE("UNIT_SPELLCAST_CHANNEL_STOP", "player", "cast-guid", 7620)
       ADVANCE(4)`);
  assert.equal(get(fish("empty")), 1);
  assert.equal(get(fish("count")), 0);
});

test("fishing: a mob looted while the bobber is out isn't a catch", () => {
  const { run, get } = vm();
  run(`${FISH}
       ${cast(7620)}
       ADVANCE(5)
       LOOT_SLOTS = { 4306 }; FISHING_LOOT = false
       FIRE("LOOT_READY"); FIRE("LOOT_OPENED"); GAIN(80)
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(4306) .. ".")
       FIRE("LOOT_CLOSED")
       ADVANCE(8)   -- the fish bites after the mob was looted
       LOOT_SLOTS = { 6303 }; FISHING_LOOT = true
       FIRE("LOOT_READY")
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(6303) .. ".")
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(`${fish("items")}[4306]`), null);
  assert.equal(get(fish("copper")), 0);
  assert.equal(get("LOG(1)"), "loot 80");
  assert.equal(get(`${fish("items")}[6303]`), 1);  // the catch still counts
  assert.equal(get(fish("count")), 1);
});

test("fishing: detected by name with a modern-client spell ID", () => {
  const { run, get } = vm();
  run(`${FISH}
       SPELLS[999001] = "Fishing"
       ${cast(999001)}
       ADVANCE(12)
       LOOT_SLOTS = { 6303 }; FISHING_LOOT = true
       FIRE("LOOT_READY")
       FIRE("CHAT_MSG_LOOT", "You receive loot: " .. LINK(6303) .. "x2.")
       FIRE("LOOT_CLOSED"); ADVANCE(5)`);
  assert.equal(get(`${fish("items")}[6303]`), 2);
});
