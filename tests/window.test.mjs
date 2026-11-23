// The window header (UI/Window.lua): a "Reload for newer prices" button once the
// loaded prices are an hour old, since WoW reads new price files only on /reload.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { luaVM, ADDON } from "./harness.mjs";

// Every file in .toc order, so the window has its real tabs.
const FILES = fs.readFileSync(path.join(ADDON, "LootLedger.toc"), "utf8")
  .split(/\r?\n/).filter((l) => l.endsWith(".lua")).map((l) => l.replace(/\\/g, "/"));

const feedAged = (mins) => `
  LootLedgerPrices = { updated = NOW - ${mins} * 60, spd = {}, houses = {
    [113] = { name = "Horde", faction = "Horde", updated = NOW - ${mins} * 60, listings = 10, items = {} },
  } }
  RELOADS = 0
  ReloadUI = function() RELOADS = RELOADS + 1 end
  SlashCmdList = {}
  StaticPopupDialogs = {}
  StaticPopup_Show = function() end
  -- WoW's Lua extras the UI files use
  tinsert, tremove = table.insert, table.remove
  wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  strsplit = function(sep, s) local out = {} for p in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = p end return unpack(out) end
  UISpecialFrames = {}
  IsShiftKeyDown, IsControlKeyDown, IsAltKeyDown = function() return false end, function() return false end, function() return false end
`;

test("prices under an hour old: no reload button", () => {
  const { run, get } = luaVM({ files: FILES, before: feedAged(20) });
  run(`ns.OpenTab("home")`);
  assert.equal(get("ns.reloadButton:IsShown()"), false);
});

test("prices an hour old or more: the button shows, and a click reloads the UI", () => {
  const { run, get } = luaVM({ files: FILES, before: feedAged(75) });
  run(`ns.OpenTab("home")`);
  assert.equal(get("ns.reloadButton:IsShown()"), true);
  run(`ns.reloadButton:GetScript("OnClick")(ns.reloadButton)`);
  assert.equal(get("RELOADS"), 1);
});

// Find the text of rows a tab renders (labels, notes, section titles).
const rowsText = `(function(rows) local out = {} for _, r in ipairs(rows) do
  out[#out + 1] = (r.kind or "") .. ":" .. tostring(r.text or r.label or "") .. "|" .. tostring(r.note or "") end
  return table.concat(out, string.char(10)) end)`;

test("trending wait screen: met requirement marked done, says what it waits for and when", () => {
  const { run, get } = luaVM({ files: FILES, before: feedAged(20).replace("items = {} },",
    `items = {}, trending = { ready = false, hoursOfData = 12.01, baselineDays = 0, readyAt = NOW + 2 * 86400 } },`) });
  const text = get(`${rowsText}(ns.Views.trending("hot", nil, "all"))`);
  assert.match(text, /row:Hours of purchase data, last 24h\|.*done/);
  assert.match(text, /row:Full days to learn "normal"\|need 2 days/);
  assert.match(text, /Waiting for full days of purchase data\. The lists should appear with the first price update after/);
  assert.equal(get(`ns.GetTab("market").choices("hot")`), null, "no filter dropdown while there's nothing to filter");
  run(`ns.OpenTab("market", "hot")`); // draws without errors
});

test("Sell tab has a Crashed list with its own description", () => {
  const { get } = luaVM({ files: FILES, before: feedAged(20) });
  const text = get(`${rowsText}(ns.GetTab("sell").render("CRASH"))`);
  assert.match(text, /section:Crashed  \(0\)/);
  assert.match(text, /dropped hard since yesterday/);
  assert.match(get(`${rowsText}(ns.GetTab("sell").render("ALL"))`), /Net worth on Home also counts/);
});

test("header: a fresh scan shows as the prices' time and hides Reload; an old scan doesn't", () => {
  const { run, get } = luaVM({ files: FILES, before: feedAged(75) });
  assert.match(get("ns.HeaderText()"), /prices 75 min old/);
  assert.equal(get("select(2, ns.HeaderText())"), true);
  run(`ns.acc.scans = { [113] = { t = NOW - 120, items = {} } }; ns.db.house = 113`);
  assert.match(get("ns.HeaderText()"), /prices scanned 2 min ago/);
  assert.equal(get("select(2, ns.HeaderText())"), false, "no Reload while the scan is fresh");
  run(`ns.acc.scans[113].t = NOW - 70 * 60`);
  assert.equal(get("select(2, ns.HeaderText())"), true);
});

test("readable times", () => {
  const { get } = luaVM({ files: FILES, before: feedAged(20) });
  assert.equal(get("ns.Ago(20)"), "just now");
  assert.equal(get("ns.Ago(5 * 60)"), "5 min ago");
  assert.equal(get("ns.Ago(3 * 3600)"), "3 h ago");
  assert.equal(get("ns.Ago(3 * 86400)"), "3 days ago");
});
