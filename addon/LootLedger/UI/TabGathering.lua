-- Loot Ledger: Gathering tab. "Summary" compares all activities for the
-- chosen period; each activity filter shows the details.

local ADDON, ns = ...
local G = ns.Gathering
local T = ns.Theme
local C = T.C

local function Plural(n, unit)
  if n == 1 then return n .. " " .. (unit:gsub("s$", "")) end
  return n .. " " .. unit
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
    local note = Plural(e.t.count, e.a.unit)
    if period == "session" then
      local gph = G.PerHour(e.a.key)
      if gph then note = note .. "  ·  " .. ns.Money(gph) .. " per hour" end
    end
    rows[#rows + 1] = { kind = "row", icon = T.ActivityIcon(e.a), label = e.a.label, note = note,
      value = ns.Money(e.value), bar = list[1].value > 0 and e.value / list[1].value or 0 }
  end
  rows[#rows + 1] = { kind = "note",
    text = "Value = gold looted + items at their AH market price. Items without an AH price count as 0." }
  rows[#rows + 1] = { kind = "note", text = ns.Prices.StatusText() }
  return rows
end

local function RenderActivity(a, period)
  local t = G.Sum(a.key, period)
  local title, sub = ns.PeriodTitle(period, ns.Ledger.FirstDay())
  local rows = { { kind = "title", icon = T.ActivityIcon(a), text = a.label .. "  ·  " .. title, sub = sub } }
  local unitName = a.unit:gsub("s$", "")
  local tries = t.count + t.empty
  local value = G.Value(t)

  local third
  if period == "session" then
    local gph = G.PerHour(a.key)
    third = { label = "Per hour", value = gph and ns.Money(gph) or "--", color = C.green }
  else
    third = { label = "Average per " .. unitName, value = t.count > 0 and ns.Money(value / t.count) or "--", color = C.blue }
  end
  rows[#rows + 1] = { kind = "tiles", tiles = {
    { label = "Total value", value = ns.Money(value) },
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
  rows[#rows + 1] = { kind = "row", icon = T.GOLD_ICON, label = "Gold looted", value = ns.Money(t.copper) }
  local itemsValue, _, unpriced = G.ItemsValue(t.items)
  rows[#rows + 1] = { kind = "row", icon = T.BAG_ICON, label = "Items", note = "at AH price",
    value = ns.Money(itemsValue) }
  if unpriced > 0 then
    rows[#rows + 1] = { kind = "row", label = unpriced .. " items without an AH price",
      note = "not listed on your AH right now, counted as 0", value = T.Color("?", C.muted) }
  end
  rows[#rows + 1] = { kind = "row", label = "Empty " .. a.unit, value = tostring(t.empty) }
  if period == "all" and t.best and t.best > 0 then
    rows[#rows + 1] = { kind = "row", label = "Best single " .. unitName, value = ns.Money(t.best) }
  end

  -- Items looted
  local b = G.Bucket(a.key)
  local ids = {}
  for id in pairs(t.items or {}) do ids[#ids + 1] = id end
  table.sort(ids, function(x, y) return t.items[x] > t.items[y] end)
  if #ids > 0 then
    rows[#rows + 1] = { kind = "section", text = "Items looted" }
    local top = t.items[ids[1]]
    for i = 1, math.min(8, #ids) do
      local id = ids[i]
      local it = ns.acc.items and ns.acc.items[id]
      local name = b.names[id] or ("item " .. id)
      rows[#rows + 1] = { kind = "row", icon = T.ItemIcon(id), itemID = id,
        label = T.QualityText(name, it and it.quality), value = t.items[id] .. "x",
        bar = t.items[id] / top, barColor = C.blue }
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
        rows[#rows + 1] = { kind = "row", label = label, note = Plural(e.d.count, a.unit),
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

local subtabs = { { key = "summary", label = "Summary" } }
for _, a in ipairs(G.ACTIVITIES) do subtabs[#subtabs + 1] = { key = a.key, label = a.label } end

ns.RegisterTab({ key = "gathering", label = "Gathering", periods = true, subtabs = subtabs, render = Render })
