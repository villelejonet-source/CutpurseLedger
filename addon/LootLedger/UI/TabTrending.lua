-- Cutpurse Ledger: Trending tab. What's selling fast, getting pricier, drying up
-- or cooling off on your auction house right now, from the hourly price feed.
-- The guardrails (real money, many separate buyers, spread over the day, still
-- going) are applied by the feed; here we filter by item type.

local ADDON, ns = ...
local T = ns.Theme
local C = T.C
local P = ns.Prices

local LISTS = {
  { key = "hot",      label = "Selling fast",   desc = "Bought much faster than usual today, by many separate buyers, and still going." },
  { key = "climbing", label = "Price climbing", desc = "Market price up a lot in 24 hours, with real volume behind it." },
  { key = "drying",   label = "Drying up",      desc = "Listings shrinking fast while people keep buying: sellers can't keep up." },
  { key = "cooling",  label = "Cooling off",    desc = "Selling much slower than usual. If you hold some, consider selling before the price follows." },
}
local FILTERS = {
  { key = "all",   label = "All" },
  { key = "quest", label = "Quest items" },
  { key = "trade", label = "Trade goods" },
  { key = "consumable", label = "Consumables" },
  { key = "gear",  label = "Gear" },
  { key = "mine",  label = "I own" },
}
local QUEST_LEVEL = 50  -- "Quest items" means items needed for level 50+ quests
local CONF = { [0] = { "early", C.muted }, [1] = { "moderate", C.blue }, [2] = { "strong", C.green } }

local function Pct(x) return string.format("%+d%%", math.floor(x * 100 + 0.5)) end

local function Owned(id)
  local total = 0
  for _, ch in ipairs(ns.Inventory.RealmChars()) do total = total + ns.Inventory.Count(ch, id) end
  return total
end

-- Does this item pass the filter? nil = item data not loaded yet (kept, re-checked on refresh).
local function Passes(id, filter, info)
  if info then
    if info.quality == 0 then return false end      -- grey junk: never
    if info.bindType == 1 then return false end     -- binds on pickup: can't be traded
  end
  if filter == "all" then return true end
  if filter == "mine" then return Owned(id) > 0 end
  if filter == "quest" then
    local lvl = ns.Quests.Level(id)
    return lvl ~= nil and lvl >= QUEST_LEVEL
  end
  if not info then return nil end
  if filter == "trade" then return info.classID == 7 end
  if filter == "consumable" then return info.classID == 0 end
  if filter == "gear" then return info.classID == 2 or info.classID == 4 end
  return true
end

local function Reason(key, e)
  local normal = e.normal and e.normal > 0 and (" (normal ~" .. e.normal .. "/day)") or ""
  local price = e.priceChange and math.abs(e.priceChange) >= 0.01 and ("price " .. Pct(e.priceChange)) or nil
  local supply = e.supplyChange and math.abs(e.supplyChange) >= 0.01 and ("listings " .. Pct(e.supplyChange)) or nil
  if key == "hot" then
    return e.sold24 .. " bought in 24h across " .. e.auctions24 .. " auctions" .. normal .. (price and (" · " .. price) or "")
  elseif key == "climbing" then
    return (price or "price up") .. " in 24h · " .. e.sold24 .. " bought" .. normal
  elseif key == "drying" then
    return (supply or "listings down") .. " in 24h · " .. e.sold24 .. " bought" .. normal
  end
  return e.sold24 .. " bought in 24h" .. normal .. (price and (" · " .. price) or "")
end

local NEED_HOURS, NEED_DAYS = 12, 2  -- as in the feed (poller/trending.mjs)

-- One requirement: met (green, "done") or still filling (blue bar).
local function Requirement(label, have, need, what)
  local done = have >= need
  return { kind = "row", label = label,
    note = done and T.Color("done", C.green) or ("need " .. need .. " " .. what),
    value = tostring(math.floor(have + 0.5)), bar = math.min(1, have / need), barColor = done and C.green or C.blue }
end

local function NotReady(t)
  local hours, days = t and t.hoursOfData or 0, t and t.baselineDays or 0
  local rows = {}
  rows[#rows + 1] = { kind = "note", text = "Trending needs history first: the feed compares hourly snapshots of your auction house to see what was really bought, and needs a few full days to know what \"normal\" is." }
  rows[#rows + 1] = Requirement("Hours of purchase data, last 24h", hours, NEED_HOURS, "hours")
  rows[#rows + 1] = Requirement("Full days to learn \"normal\"", days, NEED_DAYS, "days of 18+ hours, before the last 24h")
  local waiting = hours < NEED_HOURS and "more hours of purchase data" or "full days of purchase data"
  if t and t.readyAt and t.readyAt > time() then
    rows[#rows + 1] = { kind = "note", text = "Waiting for " .. waiting .. ". The lists should appear with the first price update after "
      .. T.Color(date("%a %d %b, %H:%M", t.readyAt), C.text) .. " (your time), if the feed keeps running every hour." }
  else
    rows[#rows + 1] = { kind = "note", text = "Waiting for " .. waiting .. ". This fills in by itself: keep Cutpurse Ledger Prices updated." }
  end
  return rows
end

local function Render(listKey, _, filter)
  local t = P.Trending()
  local list = LISTS[1]
  for _, l in ipairs(LISTS) do if l.key == listKey then list = l end end
  local status = P.Status()
  local rows = { { kind = "title", icon = T.GOLD_ICON, text = "Trending", sub = (status.houseName or "your auction house") .. (status.house and (" " .. status.house) or "") .. ", last 24 hours" } }

  if not t or not t.ready then
    for _, r in ipairs(NotReady(t)) do rows[#rows + 1] = r end
    return rows
  end

  rows[#rows + 1] = { kind = "note", text = list.desc }
  if filter == "quest" and ns.Quests.State() ~= "ready" then
    rows[#rows + 1] = { kind = "note", text = ns.Quests.Available()
      and "Reading Questie's quest database, one moment..."
      or "Quest items needs the Questie addon: it knows which items quests ask for. Install Questie to use this filter." }
    if not ns.Quests.Available() then return rows end
  end

  local shown, waiting = 0, 0
  for _, e in ipairs(t.lists[list.key] or {}) do
    local info = ns.ItemDetails(e.id)
    local ok = Passes(e.id, filter, info)
    if ok == nil then waiting = waiting + 1 end
    if ok then
      shown = shown + 1
      local p = P.Get(e.id)
      local quality = info and info.quality
      local name = info and info.name or (ns.acc.items[e.id] and ns.acc.items[e.id].name) or ("item " .. e.id)
      local owned = Owned(e.id)
      local quests = ns.Quests.For(e.id)
      local note = Reason(list.key, e)
      if quests then note = note .. " · " .. (CONF[e.conf] or CONF[0])[1] .. " signal" end
      if owned > 0 then note = note .. " · you own " .. owned end
      local conf = CONF[e.conf] or CONF[0]
      rows[#rows + 1] = {
        kind = "row", icon = T.ItemIcon(e.id), itemID = e.id,
        badge = quests and { text = "Quest " .. quests[1].level, color = C.gold } or { text = conf[1], color = conf[2] },
        label = T.QualityText(name, quality), note = note,
        value = p.hasAH and ns.Money(P.AHPrice(p)) or "",
      }
    end
  end
  if shown == 0 then
    rows[#rows + 1] = { kind = "note", text = waiting > 0 and "Loading item details..." or "Nothing here right now." }
  end
  rows[#rows + 1] = { kind = "space", h = 6 }
  rows[#rows + 1] = { kind = "note", text = ("Based on %d hours of purchase data and %d days of normal sales. Greys and items that can't be traded are hidden. Badge: how sure the signal is, or Quest N = needed for a level N quest (via Questie)."):format(t.hoursOfData, t.baselineDays) }
  return rows
end

ns.Views.trending = Render  -- shown as Market > Selling fast / Price climbing / ...
ns.Views.trendingLists = LISTS
ns.Views.trendingFilters = FILTERS
