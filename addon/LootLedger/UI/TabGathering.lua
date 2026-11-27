-- Cutpurse Ledger: gathering pages, shown under the Earnings tab. "Summary" compares all activities for the
-- chosen period; each activity filter shows the details.

local ADDON, ns = ...
local G = ns.Gathering
local T = ns.Theme
local C = T.C

-- "1 skin", "3 skins"; an activity can name its singular (a.one: "catch").
local function Plural(n, a)
  if n == 1 then return n .. " " .. (a.one or (a.unit:gsub("s$", ""))) end
  return n .. " " .. a.unit
end

local function RenderSummary(period)
  local title, sub = ns.PeriodTitle(period, ns.Ledger.FirstDay())
  local rows = { { kind = "title", text = title, sub = sub } }

  local list, total, tries = {}, 0, 0
  for _, a in ipairs(G.ACTIVITIES) do
    local t = G.Sum(a.key, period)
    if t.count + t.empty > 0 then
      local value = G.Value(t)
      list[#list + 1] = { a = a, t = t, value = value }
      total, tries = total + value, tries + t.count + t.empty
    end
  end
  table.sort(list, function(x, y) return x.value > y.value end)

  local tiles = { { label = "Total value", value = ns.Money(total) } }
  if period == "session" then
    local elapsed = GetTime() - ns.sessionStart
    tiles[2] = { label = "Per hour", value = elapsed >= 60 and ns.Money(total * 3600 / elapsed) or "--", color = C.green }
  end
  tiles[#tiles + 1] = { label = "Loot windows", value = tostring(tries), color = C.blue }
  rows[#rows + 1] = { kind = "tiles", tiles = tiles }

  if #list == 0 then
    rows[#rows + 1] = { kind = "note", text = "No pickpocketing or gathering " .. ns.PeriodPhrase(period) .. "." }
    return rows
  end
  rows[#rows + 1] = { kind = "section", text = "By activity" }
  for _, e in ipairs(list) do
    local note = Plural(e.t.count, e.a)
    if period == "session" then
      local gph = G.PerHour(e.a.key)
      if gph then note = note .. "  ·  " .. ns.Money(gph) .. " per hour" end
    end
    rows[#rows + 1] = { kind = "row", icon = T.ActivityIcon(e.a), label = e.a.label, note = note,
      value = ns.Money(e.value), bar = list[1].value > 0 and e.value / list[1].value or 0 }
  end
  rows[#rows + 1] = { kind = "note",
    text = "Value = gold looted + items at what you really get for them: your own recent sales, or the AH price when you looted them (after the AH cut). Estimates, not counted in Profit." }
  return rows
end

local function RenderActivity(a, period)
  local t = G.Sum(a.key, period)
  local title, sub = ns.PeriodTitle(period, ns.Ledger.FirstDay())
  local rows = { { kind = "title", icon = T.ActivityIcon(a), text = a.label .. "  ·  " .. title, sub = sub } }
  local unitName = a.one or a.unit:gsub("s$", "")
  local tries = t.count + t.empty
  local itemsValue, priced, unpriced, fromSales = G.ItemsValue(t.items, t)
  local value = t.copper + itemsValue

  local third
  if period == "session" then
    local gph = G.PerHour(a.key)
    third = { label = "Per hour", value = gph and ns.Money(gph) or "--", color = C.green }
  else
    third = { label = "Per " .. unitName, value = t.count > 0 and ns.Money(math.floor(value / t.count)) or "--", color = C.blue }
  end
  rows[#rows + 1] = { kind = "tiles", tiles = {
    { label = "Earned (est.)", value = ns.Money(value) },
    { label = a.unit:gsub("^%l", string.upper), value = tostring(t.count), color = C.muted },
    third,
  } }

  local rank, maxRank = ns.SkillRank(a.skill)
  if rank then
    rows[#rows + 1] = { kind = "row", icon = T.ActivityIcon(a), label = "Skill", value = rank .. " / " .. maxRank,
      bar = rank / maxRank, barColor = C.blue }
  end

  if tries == 0 then
    rows[#rows + 1] = { kind = "note", text = "No " .. a.label:lower() .. " " .. ns.PeriodPhrase(period) .. "." }
    return rows
  end

  rows[#rows + 1] = { kind = "section", text = "Breakdown" }
  if t.copper > 0 then
    rows[#rows + 1] = { kind = "row", icon = T.GOLD_ICON, label = "Gold looted", note = "exact", value = ns.Money(t.copper) }
  end
  if priced > 0 then
    local pct = math.floor(fromSales / priced * 100 + 0.5)
    rows[#rows + 1] = { kind = "row", icon = T.BAG_ICON, label = "Items (est.)",
      note = pct > 0 and (pct .. "% priced from your own sales") or "priced from AH listings",
      value = ns.Money(itemsValue) }
  end
  if unpriced > 0 then
    rows[#rows + 1] = { kind = "row", label = unpriced .. " items without any price",
      note = "never on your AH and never sold by you, counted as 0", value = T.Color("?", C.muted) }
  end

  -- Real sales of what this character gathered (all time), and what's left.
  local b = G.Bucket(a.key)
  local owned = ns.Inventory.AllItems()
  local soldNet, heldValue, any = 0, 0, false
  for id, n in pairs(b.items or {}) do
    local c = ns.Trade.Credit(id, n, owned[id] and owned[id].total or 0)
    if c.sold > 0 then soldNet, any = soldNet + c.soldNet, true end
    if c.held > 0 then
      local v = G.ItemValue(id, c.held, b)
      if v then heldValue, any = heldValue + v, true end
    end
  end
  if any then
    rows[#rows + 1] = { kind = "row", label = "Sold so far", note = "real gold after AH cut, all time",
      value = ns.Money(math.floor(soldNet + 0.5)) }
    rows[#rows + 1] = { kind = "row", label = "Still holding", note = "what you still own of it, est.",
      value = ns.Money(math.floor(heldValue + 0.5)) }
  end
  rows[#rows + 1] = { kind = "row", label = a.emptyLabel or ("Empty " .. a.unit), value = tostring(t.empty) }
  if period == "all" and t.best and t.best > 0 then
    rows[#rows + 1] = { kind = "row", label = "Best single " .. unitName, value = ns.Money(t.best) }
  end

  -- Items looted, with how each is valued
  local ids = {}
  for id in pairs(t.items or {}) do ids[#ids + 1] = id end
  local vals = {}
  for _, id in ipairs(ids) do vals[id] = { G.ItemValue(id, t.items[id], t) } end
  table.sort(ids, function(x, y) return (vals[x][1] or 0) > (vals[y][1] or 0) end)
  if #ids > 0 then
    rows[#rows + 1] = { kind = "section", text = "Items looted", right = T.Color("valued at", C.muted) }
    local top = vals[ids[1]][1] or 0
    for i = 1, math.min(10, #ids) do
      local id = ids[i]
      local v, info = vals[id][1], vals[id][2]
      local it = ns.acc.items and ns.acc.items[id]
      local name = b.names[id] or ("item " .. id)
      local how
      if not v then how = "no price"
      elseif info.source == "sales" then how = "your avg " .. ns.Money(math.floor(info.unit + 0.5)) .. " (" .. info.sales .. (info.sales == 1 and " sale)" or " sales)")
      elseif info.source == "blend" then how = ns.Money(math.floor(info.unit + 0.5)) .. " each (" .. info.sales .. (info.sales == 1 and " sale" or " sales") .. " + AH)"
      else how = (info.lootPrice and "AH price when looted, " or "AH price now, ") .. ns.Money(math.floor(info.unit + 0.5)) .. " each" end
      rows[#rows + 1] = { kind = "row", icon = T.ItemIcon(id), itemID = id,
        label = T.QualityText(name, it and it.quality) .. T.Color(" x" .. t.items[id], C.muted), note = how,
        value = v and ns.Money(math.floor(v + 0.5)) or T.Color("?", C.muted),
        bar = top > 0 and (v or 0) / top or 0, barColor = C.blue }
    end
  end

  -- By day, for multi-day periods
  if period ~= "session" and period ~= "today" then
    local keys = {}
    for k in pairs(b.days) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return x > y end)
    local limit = ns.PeriodDays(period)
    local oldest = limit and ns.DayKey(limit - 1)
    local days, best = {}, 0
    for _, k in ipairs(keys) do
      if #days >= 10 or (oldest and k < oldest) then break end
      local d = b.days[k]
      local v = G.Value(d)
      days[#days + 1] = { k = k, d = d, v = v }
      best = math.max(best, v)
    end
    if #days > 0 then
      rows[#rows + 1] = { kind = "section", text = "By day" }
      for _, e in ipairs(days) do
        local label = e.k == ns.DayKey(0) and "Today" or (e.k == ns.DayKey(1) and "Yesterday" or e.k)
        rows[#rows + 1] = { kind = "row", label = label, note = Plural(e.d.count, a),
          value = ns.Money(e.v), bar = best > 0 and e.v / best or 0 }
      end
    end
  end
  return rows
end

local function Render(key, period)
  if key == "summary" then return RenderSummary(period) end
  return RenderActivity(G.BY_KEY[key], period)
end

ns.Views.gathering = Render  -- shown under Earnings (Summary and one subtab per activity)
