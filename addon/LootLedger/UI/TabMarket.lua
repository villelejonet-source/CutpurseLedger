-- Cutpurse Ledger: Market tab. Price history and trend for one item:
-- how it moves day to day / week to week / month to month, which weekdays it
-- is cheapest and most expensive, and what to do about it.
--
-- Open it: Alt+click an item in your bags, click an item row in any tab, or
-- /cl market <item link or name>.

local ADDON, ns = ...
local T = ns.Theme
local C = T.C
local P = ns.Prices

local VIEWS = {
  { key = "day",   label = "Last 30 days" },
  { key = "week",  label = "12 weeks" },
  { key = "month", label = "12 months" },
}
local RECENT_MAX = 8

local function Pct(x, digits)
  return string.format(digits and "%+.1f%%" or "%+d%%", digits and x * 100 or math.floor(x * 100 + 0.5))
end

local function DateTime(key)
  local y, m, d = key:match("(%d+)-(%d+)-?(%d*)")
  return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) or 15, hour = 12 })
end

local LABEL = {
  day = function(k) return ns.ShortDate(DateTime(k)) end,
  week = function(k) return "w/c " .. ns.ShortDate(DateTime(k)) end,
  month = function(k) return date("%b %Y", DateTime(k)) end,
}

local function ItemName(id)
  local name, _, quality = ns.ItemInfo(id)
  local it = ns.acc.items and ns.acc.items[id]
  return name or (it and it.name) or ("item " .. id), quality or (it and it.quality)
end

-- Remember the item and open the tab.
function ns.OpenMarket(itemID)
  if not itemID then return end
  ns.ui.marketItem = itemID
  local recent = ns.ui.marketRecent or {}
  for i = #recent, 1, -1 do if recent[i] == itemID then table.remove(recent, i) end end
  table.insert(recent, 1, itemID)
  while #recent > RECENT_MAX do table.remove(recent) end
  ns.ui.marketRecent = recent
  ns.OpenTab("market")
end

-- Change from the previous value with data, for "this week vs last week".
local function LastChange(values)
  local last, prev
  for i = #values, 1, -1 do
    if values[i] then
      if not last then last = values[i] elseif not prev then prev = values[i]; break end
    end
  end
  return last and prev and (last / prev - 1) or nil
end

local SupplyRows  -- defined below Render

local function Empty()
  local rows = {
    { kind = "title", icon = T.GOLD_ICON, text = "Market", sub = "price history for one item" },
    { kind = "note", text = "Alt+click an item in your bags, click an item row in Inventory, Gathering or the Gold log, or type /cl market and shift-click an item into the chat line." },
  }
  local recent = ns.ui.marketRecent or {}
  if #recent > 0 then
    rows[#rows + 1] = { kind = "section", text = "Recently viewed" }
    for _, id in ipairs(recent) do
      local name, q = ItemName(id)
      local p = P.Get(id)
      rows[#rows + 1] = { kind = "row", icon = T.ItemIcon(id), itemID = id, label = T.QualityText(name, q),
        value = p.hasAH and ns.Money(P.AHPrice(p)) or T.Color("no AH price", C.muted) }
    end
  end
  return rows
end

local function Render(view)
  local id = ns.ui.marketItem
  if not id then return Empty() end

  local name, quality = ItemName(id)
  local p = P.Get(id)
  local h = P.History(id)
  local d = ns.Advisor.Decide(id)
  local status = P.Status()
  local ah = p.hasAH and P.AHPrice(p) or nil
  local normal = p.hasAH and P.NormalPrice(p, id) or nil

  local rows = {
    { kind = "title", icon = T.ItemIcon(id), text = T.QualityText(name, quality),
      sub = status.house and ("house " .. status.house) or "" },
  }

  -- Now / vs normal / trend
  local vs = ah and normal and normal > 0 and (ah / normal - 1) or nil
  local trend = h and h.trend
  rows[#rows + 1] = { kind = "tiles", tiles = {
    { label = "AH price now", value = ah and ns.Money(ah) or "-" },
    { label = "vs recent normal", value = vs and T.Color(Pct(vs), vs >= 0 and C.green or C.red) or "-",
      color = vs and (vs >= 0 and C.green or C.red) or C.muted },
    { label = "Trend", value = trend and T.Color(Pct(trend, true) .. " / day", trend >= 0 and C.green or C.red) or "-",
      color = trend and (trend >= 0 and C.green or C.red) or C.muted },
  } }

  local badgeColors = { SELL = C.green, LIST = C.gold, HOLD = C.blue, CHECK = { 1, 0.6, 0.2, 1 },
    VENDOR = { 0.75, 0.75, 0.75, 1 }, KEEP = C.muted }
  rows[#rows + 1] = { kind = "row", badge = { text = ns.Advisor.ACTIONS[d.action].label, color = badgeColors[d.action] },
    label = d.reason, value = d.unit and d.unit > 0 and (ns.Money(d.unit) .. T.Color(" each", C.muted)) or "" }

  if not h then
    rows[#rows + 1] = { kind = "note", text = p.hasAH
      and "No history for this item yet: it trades too rarely on your AH to track (under 5 sold a day and under 20 listed)."
      or "This item isn't listed on your AH right now." }
    return SupplyRows(rows, id, p, nil)
  end

  -- Price chart
  local series = view == "week" and h.weekly or (view == "month" and h.monthly or h.daily)
  local labels = {}
  for i, k in ipairs(series.labels) do labels[i] = LABEL[view](k) end
  rows[#rows + 1] = { kind = "section", text = "Price",
    right = T.Color(view == "week" and "weekly average" or (view == "month" and "monthly average" or "daily average"), C.muted) }
  rows[#rows + 1] = { kind = "chart", values = series.values, labels = labels, height = 150,
    empty = view == "day" and "Needs at least 2 days of history" or ("Needs at least 2 " .. (view == "week" and "weeks" or "months") .. " of history") }

  -- Movement
  local dayMove = LastChange(h.daily.values)
  local weekMove = LastChange(h.weekly.values)
  local monthMove = LastChange(h.monthly.values)
  if dayMove then rows[#rows + 1] = { kind = "row", label = "Since yesterday", value = T.Color(Pct(dayMove, true), dayMove >= 0 and C.green or C.red) } end
  if weekMove then rows[#rows + 1] = { kind = "row", label = "This week vs last week", note = "this week so far", value = T.Color(Pct(weekMove, true), weekMove >= 0 and C.green or C.red) } end
  if monthMove then rows[#rows + 1] = { kind = "row", label = "This month vs last month", note = "this month so far", value = T.Color(Pct(monthMove, true), monthMove >= 0 and C.green or C.red) } end
  if h.volatility then
    rows[#rows + 1] = { kind = "row", label = "Typical day-to-day move", note = h.volatility > 0.1 and "jumpy item" or nil,
      value = "±" .. string.format("%.1f%%", h.volatility * 100) }
  end
  if not (dayMove or weekMove or monthMove) then
    rows[#rows + 1] = { kind = "note", text = "History started " .. (h.daily.labels[1] and LABEL.day(h.daily.labels[1]) or "today") .. ". Movement shows up from the second day." }
  end

  -- Weekly pattern
  local wk = P.WeekdayAdvice(h)
  rows[#rows + 1] = { kind = "section", text = "Weekly pattern",
    right = T.Color(h.weeks .. (h.weeks == 1 and " week" or " weeks") .. " of data", C.muted) }
  local bars = {}
  for i = 1, 7 do
    local v = h.weekday[i]
    local color = { 0.55, 0.55, 0.6, 1 }
    if wk then
      for _, b in ipairs(wk.best) do if b == i then color = C.green end end
      for _, w in ipairs(wk.worst) do if w == i then color = C.red end end
    end
    bars[i] = { label = P.DAY_SHORT[i], value = v or nil, text = v and Pct(v, true) or nil, color = color }
  end
  rows[#rows + 1] = { kind = "bars", bars = bars, height = 120 }

  if wk then
    local base = normal or ah
    local afterCut = (1 + wk.spread) * (1 - ns.Advisor.SETTINGS.ahCut) - 1
    rows[#rows + 1] = { kind = "row", badge = { text = "Buy", color = C.blue },
      label = "Cheapest: " .. P.DayList(wk.worst, true), note = Pct(wk.worstPct, true) .. " vs the week",
      value = base and ("~" .. ns.Money(base * (1 + wk.worstPct))) or "" }
    rows[#rows + 1] = { kind = "row", badge = { text = "Sell", color = C.green },
      label = "Most expensive: " .. P.DayList(wk.best, true), note = Pct(wk.bestPct, true) .. " vs the week",
      value = base and ("~" .. ns.Money(base * (1 + wk.bestPct))) or "" }
    if afterCut >= 0.05 then
      rows[#rows + 1] = { kind = "note", text = ("Recommend: buy %s, sell %s. Spread %s, %s after the 5%% AH cut. Pattern held in %d%% of the last %d weeks.")
        :format(P.DayList(wk.worst, true), P.DayList(wk.best, true), Pct(wk.spread), Pct(afterCut), math.floor(h.consistency * 100 + 0.5), h.weeks) }
    else
      rows[#rows + 1] = { kind = "note", text = ("Recommend: sell on %s. The spread (%s) is too small to buy and resell after the 5%% AH cut.")
        :format(P.DayList(wk.best, true), Pct(wk.spread)) }
    end
  elseif h.weeks < 2 then
    rows[#rows + 1] = { kind = "note", text = ("No weekly pattern yet: needs at least 2 full weeks of prices (has %d). Prices are collected every hour, so this fills in by itself.")
      :format(h.weeks) }
  else
    rows[#rows + 1] = { kind = "note", text = "No reliable weekly pattern: the weekday differences are within normal day-to-day noise, or they change from week to week. Sell whenever the advice above says so." }
  end

  return SupplyRows(rows, id, p, h)
end

-- Supply, purchases, trending and quests: shown even for items without price history.
function SupplyRows(rows, id, p, h)
  rows[#rows + 1] = { kind = "section", text = "Supply" }
  if p.auctions then
    local note = h and h.usualQty and h.usualQty > 0 and ("usually ~" .. math.floor(h.usualQty + 0.5)) or nil
    if note and p.auctions > h.usualQty * 1.5 then note = note .. ", flooded" elseif note and p.auctions < h.usualQty * 0.6 then note = note .. ", scarce" end
    rows[#rows + 1] = { kind = "row", label = "Listed now", note = note, value = tostring(p.auctions) }
  end
  if p.min then rows[#rows + 1] = { kind = "row", label = "Lowest listing", value = ns.Money(p.min) } end
  local sales = P.Sales(id)
  if sales then
    local note = sales.normal and ("normal ~" .. sales.normal .. "/day") or "normal not known yet"
    note = note .. ", " .. sales.auctions24 .. " separate auctions"
    local hot = sales.normal and sales.normal > 0 and sales.sold24 >= 1.8 * sales.normal
    rows[#rows + 1] = { kind = "row", label = "Bought on your AH, last 24h", note = note,
      value = hot and T.Color(tostring(sales.sold24), C.green) or tostring(sales.sold24) }
  end
  local trend = P.Trending()
  local tr = trend and trend.byItem[id]
  if tr then
    local names = { hot = "Selling fast", climbing = "Price climbing", drying = "Drying up", cooling = "Cooling off" }
    rows[#rows + 1] = { kind = "row", badge = { text = "Trending", color = C.green }, label = names[tr.list] or tr.list,
      note = "see the Trending tab" }
  end
  local quests = ns.Quests.For(id)
  if quests then
    rows[#rows + 1] = { kind = "section", text = "Needed for quests", right = T.Color("via Questie", C.muted) }
    for i = 1, math.min(5, #quests) do
      local q = quests[i]
      rows[#rows + 1] = { kind = "row", badge = { text = "Lvl " .. q.level, color = C.gold }, label = q.name }
    end
    if #quests > 5 then rows[#rows + 1] = { kind = "note", text = "...and " .. (#quests - 5) .. " more." } end
  end
  if p.soldPerDay then rows[#rows + 1] = { kind = "row", label = "Sold per day (EU)", note = "Saddlebag Exchange", value = tostring(p.soldPerDay) } end
  rows[#rows + 1] = { kind = "note", text = P.StatusText() }
  return rows
end

ns.RegisterTab({ key = "market", label = "Market", subtabs = VIEWS, render = Render })

-- Alt+click an item anywhere (bags, chat links, ...) to open its history.
ns.Hook("HandleModifiedItemClick", function(link)
  if link and IsAltKeyDown and IsAltKeyDown() and not (IsShiftKeyDown() or IsControlKeyDown()) then
    local id = tonumber(link:match("item:(%d+)"))
    if id then ns.OpenMarket(id) end
  end
end)
