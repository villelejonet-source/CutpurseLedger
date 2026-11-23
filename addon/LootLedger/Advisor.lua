-- Cutpurse Ledger: advisor
-- One decision per item: SELL now, HOLD for a better price, LIST at the normal
-- price, or VENDOR it. Every decision comes with a short reason.
--
-- Rule of the house: anything white or better that can go on the AH goes on
-- the AH. Only grey junk, soulbound items, and items the AH pays LESS for than
-- a vendor are ever marked Vendor.

local ADDON, ns = ...
local A = {}
ns.Advisor = A

A.SETTINGS = {
  ahCut = 0.05,          -- AH keeps 5% of the sale price
  highVsNormal = 0.10,   -- 10% above the recent normal = sell now
  spike = 0.25,          -- 25% above = call it a spike
  lowVsNormal = -0.10,   -- 10% below normal = hold (only if not falling)
  fallingTrend = -0.01,  -- losing 1%+ a day = sell now, don't hold
  risingTrend = 0.015,   -- gaining 1.5%+ a day = wait a little (unless it's a spike)
}

A.ACTIONS = {
  SELL   = { label = "Sell now",    color = "ff4cff4c", order = 1 },
  LIST   = { label = "List",        color = "ffffd100", order = 2 },
  HOLD   = { label = "Hold",        color = "ff66b3ff", order = 3 },
  CHECK  = { label = "No AH price", color = "ffff9933", order = 4 },
  VENDOR = { label = "Vendor",      color = "ffbbbbbb", order = 5 },
  KEEP   = { label = "Keep",        color = "ff777777", order = 6 },
}

-- Can this item be sold on the AH (white or better, not soulbound)?
function A.IsAHItem(id)
  local item = ns.acc and ns.acc.items and ns.acc.items[id] or {}
  if item.bound then return false end
  local q = item.quality or select(3, ns.ItemInfo(id))
  return q ~= nil and q >= 1
end

local function Pct(x) return string.format("%+d%%", math.floor(x * 100 + 0.5)) end

local function Quality(id)
  local it = ns.acc and ns.acc.items and ns.acc.items[id]
  if it and it.quality then return it.quality end
  return select(3, ns.ItemInfo(id))
end

-- Returns { action, reason, unit (copper you'd get per item), ah, normal, vs }
function A.Decide(id)
  local S = A.SETTINGS
  local p = ns.Prices.Get(id)
  local vendor = p.vendor or 0
  local item = ns.acc and ns.acc.items and ns.acc.items[id] or {}

  if item.bound then
    if vendor > 0 then return { action = "VENDOR", reason = "Soulbound", unit = vendor } end
    return { action = "KEEP", reason = "Soulbound, no vendor price", unit = 0 }
  end
  if Quality(id) == 0 then
    return { action = "VENDOR", reason = "Junk", unit = vendor }
  end
  if not p.hasAH then
    -- White or better: never vendor blind. Check the AH first.
    return { action = "CHECK", reason = "Don't vendor: check the AH first", unit = 0 }
  end

  local ah = ns.Prices.AHPrice(p)
  local normal = ns.Prices.NormalPrice(p, id)
  local net = math.floor(ah * (1 - S.ahCut))
  local d = { ah = ah, normal = normal, unit = net }

  if net < vendor then
    d.action, d.reason, d.unit = "VENDOR", "AH pays less than the vendor", vendor
    return d
  end

  -- Compare with the recent normal price, and look at where the price is heading.
  -- In a young economy prices drift fast, so a falling item is sold, not held.
  local h = ns.Prices.History(id)
  local trend = h and h.trend
  d.trend = trend
  local vs = (normal and normal > 0) and (ah / normal - 1) or 0
  d.vs = vs
  local falling = trend and trend <= S.fallingTrend
  local rising = trend and trend >= S.risingTrend
  -- Order matters: a spike is always sold; a falling item is sold before it drops
  -- further; a rising item is held (the "normal" price lags a rising market, so
  -- "+12% vs normal" there is just the climb, not a peak).
  if vs >= S.spike then
    d.action, d.reason = "SELL", Pct(vs) .. " vs normal, spike"
  elseif falling then
    d.action, d.reason = "SELL", "falling " .. Pct(-trend):gsub("^%+", "") .. "/day, sell before it drops"
  elseif rising then
    d.action, d.reason = "HOLD", "rising " .. Pct(trend) .. "/day, wait a little"
  elseif vs >= S.highVsNormal then
    d.action, d.reason = "SELL", Pct(vs) .. " vs normal"
  elseif vs <= S.lowVsNormal then
    d.action, d.reason = "HOLD", Pct(vs) .. " vs normal, wait"
  else
    d.action, d.reason = "LIST", "Normal price"
  end

  -- A reliable weekly pattern: tell when to sell.
  local wk = ns.Prices.WeekdayAdvice(h)
  if wk and (d.action == "LIST" or d.action == "HOLD") then
    d.bestDays = wk.best
    d.reason = d.reason .. ", best on " .. ns.Prices.DayList(wk.best)
  end
  if (p.soldPerDay and p.soldPerDay < 10) or (not p.soldPerDay and p.saleRate and p.saleRate < 0.2) then
    d.reason = d.reason .. ", slow seller"
  end
  -- Demand signals: trending now, or wanted for high-level quests.
  local trend = ns.Prices.Trending and ns.Prices.Trending()
  local tr = trend and trend.byItem[id]
  if tr and (tr.list == "hot" or tr.list == "drying") then d.reason = d.reason .. ", in demand right now" end
  local questLevel = ns.Quests and ns.Quests.Level(id)
  if questLevel and questLevel >= 50 then d.reason = d.reason .. ", people buy it for quests" end
  return d
end

-- Decisions for everything owned on this realm, sorted by total value.
-- Each entry: { id, name, qty, decision, total }
function A.InventoryPlan()
  local list = {}
  for id, owned in pairs(ns.Inventory.AllItems()) do
    local d = A.Decide(id)
    local it = ns.acc.items[id] or {}
    list[#list + 1] = {
      id = id, name = it.name or ("item " .. id), qty = owned.total,
      chars = owned.chars, decision = d, total = (d.unit or 0) * owned.total,
    }
  end
  table.sort(list, function(x, y)
    if x.total ~= y.total then return x.total > y.total end
    return x.name < y.name
  end)
  return list
end

function A.Tag(action)
  local a = A.ACTIONS[action]
  return "|c" .. a.color .. a.label .. "|r"
end
