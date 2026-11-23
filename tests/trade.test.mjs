// Tests for the addon's trade record and loot valuation (Trade.lua + Gathering.lua),
// run in fengari (a Lua VM in JavaScript) with a few WoW functions stubbed.
// Run: npm install --no-save fengari@0.1.4 && node --test tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");
const ADDON = path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/(\w:)/, "$1")), "..", "addon", "LootLedger");
const DAY = 86400;

function vm() {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const err = () => to_jsstring(lua.lua_tostring(L, -1));
  const run = (code) => { if (lauxlib.luaL_dostring(L, to_luastring(code)) !== 0) throw new Error(err()); };
  const get = (expr) => {
    run(`__out = (${expr})`);
    lua.lua_getglobal(L, to_luastring("__out"));
    const t = lua.lua_type(L, -1);
    const v = t === lua.LUA_TNUMBER ? lua.lua_tonumber(L, -1) : t === lua.LUA_TNIL ? null : err();
    lua.lua_pop(L, 1);
    return v;
  };
  const load = (file) => {
    const src = fs.readFileSync(path.join(ADDON, file));
    if (lauxlib.luaL_loadbuffer(L, src, null, to_luastring("@" + file)) !== 0) throw new Error(err());
    lua.lua_pushstring(L, to_luastring("LootLedger"));
    lua.lua_getglobal(L, to_luastring("ns"));
    if (lua.lua_pcall(L, 2, 0, 0) !== 0) throw new Error(err());
  };
  run(`
    NOW = 1800000000
    time = function() return NOW end
    date = os.date
    GetTime = function() return NOW end
    UnitFactionGroup = function() return "Horde" end
    PRICES = {}  -- itemID -> AH price (copper), what the feed says right now
    ns = {
      acc = { chars = {}, items = {} },
      ItemInfo = function() return nil end,
      Prices = {
        Get = function(id) return { hasAH = PRICES[id] ~= nil, market = PRICES[id] } end,
        AHPrice = function(p) return p.market end,
        Status = function() return { source = "blizzard" } end,
      },
      Advisor = { SETTINGS = { ahCut = 0.05 } },
      On = function() end, OnInit = function() end, OnSessionReset = function() end,
      DayKey = function(off) return os.date("!%Y-%m-%d", NOW - (off or 0) * 86400) end,
      PeriodDays = function(p) return ({ today = 1, week = 7, month = 30 })[p] end,
      SellPrice = function() return 0 end, SpellName = function() return nil end,
    }
    ns.db = { realm = "", acts = {} }
    ns.acc.chars["-Vanish"] = ns.db
  `);
  load("Trade.lua");
  load("Gathering.lua");
  return { run, get };
}

test("your price: sale price minus AH cut, recent sales count more", () => {
  const { run, get } = vm();
  run(`ns.Trade.Sale(2318, 10, 950, NOW - 20 * 86400)   -- 95c each, 20 days ago
       ns.Trade.Sale(2318, 10, 1900, NOW)               -- 190c each, today`);
  const unit = get("ns.Trade.Realized(2318)");
  // weights 0.5^(20/14)=0.371 and 1: (0.371*950 + 1900) / (0.371*10 + 10)
  const w = 0.5 ** (20 / 14);
  assert.ok(Math.abs(unit - (w * 950 + 1900) / (w * 10 + 10)) < 0.01);
  assert.equal(get("select(2, ns.Trade.Realized(2318))"), 2);
});

test("sales older than 30 days don't set the price", () => {
  const { run, get } = vm();
  run(`ns.Trade.Sale(2318, 10, 950, NOW - 40 * 86400)`);
  assert.equal(get("ns.Trade.Realized(2318)"), null);
});

test("a sold listing gets its deposit back; an expired one loses it", () => {
  const { run, get } = vm();
  run(`ns.Trade.Posted(2318, 20, 200, NOW - 3600)   -- two stacks of 10, deposit 200 total
       ns.Trade.Sale(2318, 10, 1000, NOW)            -- first 10 sold: deposit 100 came back
       ns.Trade.Returned(2318, 10, NOW)              -- other 10 expired: 100 lost`);
  assert.equal(get("ns.Trade.Item(2318).tot.lostDep"), 100);
  assert.equal(get("#ns.Trade.Item(2318).posts"), 0);
  // 10 sold for 1000 net, 100 lost on the failed listing -> 90c per unit really
  assert.equal(get("ns.Trade.Realized(2318)"), 90);
});

test("expired auctions posted before tracking began lose nothing we know of", () => {
  const { run, get } = vm();
  run(`ns.Trade.Returned(2318, 5, NOW)`);
  assert.equal(get("ns.Trade.Item(2318).tot.lostDep"), 0);
});

test("few sales blend with the listing price; enough sales use yours only", () => {
  const { run, get } = vm();
  run(`ns.Trade.Sale(2318, 2, 200, NOW)`);                 // 1 sale, 2 units, 100c each
  // k = max(1/5, 2/20) = 0.2 -> 0.2*100 + 0.8*50
  assert.equal(get("ns.Trade.UnitValue(2318, 50)"), 60);
  assert.equal(get("select(2, ns.Trade.UnitValue(2318, 50)).source"), "blend");
  run(`for i = 1, 4 do ns.Trade.Sale(2318, 2, 200, NOW) end`); // 5 sales
  assert.equal(get("ns.Trade.UnitValue(2318, 50)"), 100);
  assert.equal(get("select(2, ns.Trade.UnitValue(2318, 50)).source"), "sales");
});

test("listing prices are discounted by how much failed listings cost you", () => {
  const { run, get } = vm();
  run(`ns.Trade.Posted(1, 1, 100, NOW); ns.Trade.Returned(1, 1, NOW)   -- 100 lost
       ns.Trade.Sale(2, 1, 1000, NOW)                                   -- 1000 earned`);
  assert.equal(get("ns.Trade.LossRate()"), 0.1);
  assert.equal(get("ns.Trade.UnitValue(999, 500)"), 450);
});

test("loot keeps the AH price it had when you looted it", () => {
  const { run, get } = vm();
  // The 5s / 10s example: skin one Rugged Leather at 5s, the next day it's 10s.
  run(`PRICES[8170] = 500
       local b = ns.Gathering.Bucket("skinning")
       b.items[8170] = 1; b.lootV[8170] = 475; b.lootN[8170] = 1   -- looted at 5s (475 after cut)
       PRICES[8170] = 1000
       b.items[8170] = 2; b.lootV[8170] = 475 + 950; b.lootN[8170] = 2`);
  // 4s75 + 9s50 = 14s25: each skin at its own day's price, after the AH cut
  assert.equal(get(`ns.Gathering.ItemsValue(ns.Gathering.Bucket("skinning").items, ns.Gathering.Bucket("skinning"))`), 1425);
  run(`PRICES[8170] = 200`); // market crashes: the past doesn't change
  assert.equal(get(`ns.Gathering.ItemsValue(ns.Gathering.Bucket("skinning").items, ns.Gathering.Bucket("skinning"))`), 1425);
});

test("once you've sold enough, your own sale price values the loot", () => {
  const { run, get } = vm();
  run(`local b = ns.Gathering.Bucket("skinning")
       b.items[8170] = 100; b.lootV[8170] = 100 * 475; b.lootN[8170] = 100
       for i = 1, 5 do ns.Trade.Sale(8170, 10, 6000, NOW) end    -- you really get 6s each`);
  assert.equal(get(`ns.Gathering.ItemsValue(ns.Gathering.Bucket("skinning").items, ns.Gathering.Bucket("skinning"))`), 60000);
});

test("sales count as gathered only up to what was gathered, split by source", () => {
  const { run, get } = vm();
  run(`ns.db.acts.skinning = { items = { [8170] = 100 } }
       ns.acc.chars["-Alt"] = { realm = "", acts = { skinning = { items = { [8170] = 100 } } } }
       ns.Trade.Sale(8170, 150, 150 * 600, NOW)   -- sold 150 of the 200 gathered on the realm
       ns.Trade.Bought(8170, 50, 50 * 500)`);
  // this character gathered half of the 200 -> credited half of the 150 sold
  assert.equal(get("ns.Trade.Credit(8170, 100, 30).sold"), 75);
  assert.equal(get("ns.Trade.Credit(8170, 100, 30).soldNet"), 75 * 600);
  // 50 left unsold on the realm, but only 30 owned -> 30 held, half of it ours
  assert.equal(get("ns.Trade.Credit(8170, 100, 30).held"), 15);

  run(`ns.Trade.Sale(8170, 100, 100 * 600, NOW)`); // 250 sold, but only 200 were ever gathered
  assert.equal(get("ns.Trade.Credit(8170, 100, 0).sold"), 100);
});

test("sale mails without a count still add gold, but don't set a price", () => {
  const { run, get } = vm();
  run(`ns.Trade.Sale(2318, nil, 5000, NOW)`);
  assert.equal(get("ns.Trade.Realized(2318)"), null);
  assert.equal(get("ns.Trade.Item(2318).tot.unknownNet"), 5000);
  assert.equal(get("ns.Trade.Item(2318).tot.soldNet"), 0);
});
