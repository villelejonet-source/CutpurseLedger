// Hourly WoW: Forever auction house snapshot -> the LootLedger_Prices data addon.
//
// Reads:  Blizzard API, namespace dynamic-forever-<region>: every auction house of
//         the ruleset (each house = /auctions/{id} + /auctions/{id}/commodities)
//         Saddlebag Exchange's free Forever endpoint for region-wide sales per day (optional)
//         <HISTORY_DIR>/<house>.json.gz from the previous run
// Writes: <OUT_DIR>/LootLedger_Prices/{LootLedger_Prices.toc, Prices.lua}   the data addon
//         <OUT_DIR>/history/<house>.json.gz                                kept for the next run
//
// Env: BNET_CLIENT_ID, BNET_CLIENT_SECRET (required)
//      BNET_REGION (default eu), AH_RULESET (default 2 = Normal),
//      AH_HOUSES   (default "all"; or a list like "113,114")
//      HISTORY_DIR (default ./history), OUT_DIR (default ./out)

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { gzipSync, gunzipSync } from "node:zlib";
import { join } from "node:path";
import { dayKey } from "./analysis.mjs";
import {
  addSnapshot, archiveOldDays, allDays, seriesFor, average, encodeHistory, labels, monthKeys, monthlyFor,
} from "./history.mjs";

const {
  BNET_CLIENT_ID, BNET_CLIENT_SECRET,
  BNET_REGION = "eu",
  AH_RULESET = "2",
  AH_HOUSES = "all",
  HISTORY_DIR = "history",
  OUT_DIR = "out",
} = process.env;

if (!BNET_CLIENT_ID || !BNET_CLIENT_SECRET) throw new Error("Set BNET_CLIENT_ID and BNET_CLIENT_SECRET");

const REGION = BNET_REGION.toLowerCase();
const NAMESPACE = `dynamic-forever-${REGION}`;
const MARKET_SHARE = 0.15;         // market value = average of the cheapest 15% of units
const HIST_MIN_SOLD_PER_DAY = 5;   // per-item history only for items that actually trade...
const HIST_MIN_LISTED = 20;        // ...or have a real market on that house
const ADDON = "LootLedger_Prices";

// ---------------------------------------------------------------------------
// Blizzard API
// ---------------------------------------------------------------------------
async function token() {
  const res = await fetch("https://oauth.battle.net/token", {
    method: "POST",
    headers: {
      Authorization: "Basic " + Buffer.from(`${BNET_CLIENT_ID}:${BNET_CLIENT_SECRET}`).toString("base64"),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  if (!res.ok) throw new Error(`OAuth token: ${res.status}`);
  return (await res.json()).access_token;
}

async function getJson(path, accessToken) {
  const url = new URL(`https://${REGION}.api.blizzard.com${path}`);
  url.searchParams.set("namespace", NAMESPACE);
  url.searchParams.set("locale", "en_GB");
  for (let attempt = 1; ; attempt++) {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
    if (res.ok) return { json: await res.json(), lastModified: res.headers.get("last-modified") };
    if (attempt >= 3 || res.status === 404) throw new Error(`${res.status} from ${url.pathname}`);
    await new Promise((r) => setTimeout(r, 2000 * attempt));
  }
}

// All houses of the ruleset: [{ id, name, faction }]
async function listHouses(accessToken) {
  const { json } = await getJson(`/data/wow/ruleset/${AH_RULESET}/auctions/`, accessToken); // trailing slash required
  const all = (json.auctions ?? []).map((h) => {
    const name = typeof h.name === "string" ? h.name : (h.name?.en_GB ?? h.name?.en_US ?? "");
    return { id: h.id, name, faction: name.split(" ")[0] || "Unknown" };
  });
  if (AH_HOUSES === "all") return all;
  const wanted = new Set(AH_HOUSES.split(",").map((s) => Number(s.trim())));
  return all.filter((h) => wanted.has(h.id));
}

// ---------------------------------------------------------------------------
// Prices per item from one house
// ---------------------------------------------------------------------------
function summarize(listings) {
  const items = {};
  for (const [id, rows] of listings) {
    rows.sort((a, b) => a[0] - b[0]);
    const qty = rows.reduce((s, r) => s + r[1], 0);
    const want = Math.max(1, Math.ceil(qty * MARKET_SHARE));
    let taken = 0, sum = 0;
    for (const [price, q] of rows) {
      const use = Math.min(q, want - taken);
      sum += price * use;
      taken += use;
      if (taken >= want) break;
    }
    items[id] = { min: Math.round(rows[0][0]), market: Math.round(sum / taken), qty, n: rows.length };
  }
  return items;
}

async function fetchHouse(house, accessToken) {
  const listings = new Map();
  const add = (id, unit, qty) => {
    if (!id || !(unit > 0) || !(qty > 0)) return;
    let rows = listings.get(id);
    if (!rows) listings.set(id, (rows = []));
    rows.push([unit, qty]);
  };
  const base = `/data/wow/ruleset/${AH_RULESET}/auctions/${house}`;
  const a = await getJson(base, accessToken);
  for (const x of a.json.auctions ?? []) {
    if (x.buyout) add(x.item?.id, x.buyout / x.quantity, x.quantity); // bid-only listings are skipped
  }
  const c = await getJson(`${base}/commodities`, accessToken);
  for (const x of c.json.auctions ?? []) add(x.item?.id, x.unit_price, x.quantity);
  return {
    items: summarize(listings),
    listings: (a.json.auctions?.length ?? 0) + (c.json.auctions?.length ?? 0),
    updated: Date.parse(a.lastModified ?? "") || Date.now(),
  };
}

// ---------------------------------------------------------------------------
// History files
// ---------------------------------------------------------------------------
async function loadHistory(house) {
  try {
    const h = JSON.parse(gunzipSync(await readFile(join(HISTORY_DIR, `${house}.json.gz`))).toString());
    h.days ??= {};
    h.months ??= {};
    return h;
  } catch {
    return { days: {}, months: {} };
  }
}

// ---------------------------------------------------------------------------
// Saddlebag Exchange: region-wide sales per day (optional extra)
// ---------------------------------------------------------------------------
async function salesPerDay() {
  try {
    const res = await fetch("https://api.saddlebagexchange.com/api/wow/forever/megaitemnames", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ region: REGION === "eu" ? "EU" : "NA", discount: 1, item_ids: [] }),
      signal: AbortSignal.timeout(60_000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const rows = await res.json();
    const out = {};
    for (const r of rows) if (r.itemID && r.salesPerDay > 0) out[r.itemID] = Math.round(r.salesPerDay);
    return out;
  } catch (e) {
    console.log(`Saddlebag sales per day unavailable: ${e.message}`);
    return {};
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const now = Date.now();
const accessToken = await token();
await mkdir(join(OUT_DIR, ADDON), { recursive: true });
await mkdir(join(OUT_DIR, "history"), { recursive: true });

const spd = await salesPerDay();
console.log(`sales per day: ${Object.keys(spd).length} items`);

const houses = await listHouses(accessToken);
const houseBlocks = [];
for (const house of houses) {
  let data;
  try {
    data = await fetchHouse(house.id, accessToken);
  } catch (e) {
    console.log(`house ${house.id} ${house.name}: ${e.message}`);
    continue;
  }
  if (data.listings === 0) {
    console.log(`house ${house.id} ${house.name}: empty, skipped`);
    continue;
  }
  const history = await loadHistory(house.id);
  addSnapshot(history, data.items, now);
  archiveOldDays(history, now);
  await writeFile(join(OUT_DIR, "history", `${house.id}.json.gz`), gzipSync(JSON.stringify(history)));

  const days = allDays(history, now);
  const months = monthKeys(history, days);
  const lines = [], histLines = [];
  for (const [id, s] of Object.entries(data.items)) {
    const series = seriesFor(history, days, id);
    // "market,min,quantity,avg7,avg30"
    lines.push(`[${id}]="${s.market},${s.min},${s.qty},${average(series, 7)},${average(series, 30)}",`);
    if ((spd[id] ?? 0) >= HIST_MIN_SOLD_PER_DAY || s.qty >= HIST_MIN_LISTED) {
      histLines.push(`[${id}]="${encodeHistory(series, monthlyFor(history, days, id, months))}",`);
    }
  }
  const daysOfHistory = Object.keys(history.days).length;
  houseBlocks.push(
    `  [${house.id}] = { name = "${house.name}", faction = "${house.faction}", updated = ${Math.floor(data.updated / 1000)}, listings = ${data.listings}, days = ${daysOfHistory},\n` +
    `    ${labels(days, months)},\n` +
    `    items = {\n${lines.join("\n")}\n    },\n` +
    `    hist = {\n${histLines.join("\n")}\n    } },`,
  );
  console.log(`house ${house.id} ${house.name}: ${data.listings} listings, ${lines.length} items (${histLines.length} with history), ${daysOfHistory} days of history`);
}
if (!houseBlocks.length) throw new Error("No auction house could be read");

const spdLines = Object.entries(spd).map(([id, n]) => `[${id}]=${n},`);
const lua = `-- Generated by Loot Ledger's price feed (poller/ah.mjs) from Blizzard's WoW: Forever auction house API. Do not edit.
-- items[id] = "market,min,quantity,avg7,avg30" (copper per unit). spd = region sales per day (Saddlebag Exchange).
-- hist[id]  = per-item history, see encodeHistory() in poller/history.mjs. dayLabels/weekLabels/monthLabels label its series.
LootLedgerPrices = {
  updated = ${Math.floor(now / 1000)},
  region = "${REGION}", ruleset = ${AH_RULESET},
  houses = {
${houseBlocks.join("\n")}
  },
  spd = {
${spdLines.join("\n")}
  },
}
`;
const stamp = new Date(now).toISOString().slice(0, 16).replace("T", " ");
await writeFile(join(OUT_DIR, ADDON, "Prices.lua"), lua);
await writeFile(join(OUT_DIR, ADDON, `${ADDON}.toc`), `## Interface: 16001
## Title: Loot Ledger Prices (${REGION.toUpperCase()})
## Notes: Auction house prices for Loot Ledger, ${stamp} UTC. Updated automatically through your addon manager.
## Author: Loot Ledger
## Version: ${new Date(now).toISOString().slice(0, 13).replace(/[-T]/g, ".")}

Prices.lua
`);
console.log(`Prices.lua: ${(lua.length / 1e6).toFixed(2)} MB, ${houseBlocks.length} houses`);
