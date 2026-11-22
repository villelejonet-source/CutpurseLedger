-- Loot Ledger: Gold log tab. Every gold movement in the chosen period,
-- grouped by day (with each day's profit), newest first.

local ADDON, ns = ...
local T = ns.Theme
local C = T.C
local MAX_ENTRIES = 80

local function DayLabel(t)
  local key = date("%Y-%m-%d", t)
  if key == ns.DayKey(0) then return "Today" end
  if key == ns.DayKey(1) then return "Yesterday" end
  return date("%A ", t) .. ns.ShortDate(t)
end

local function DayProfit(key)
  local net = 0
  for _, e in pairs(ns.db.ledger.days[key] or {}) do net = net + e.inc - e.exp end
  return net
end

local function Render(_, period)
  local title, sub = ns.PeriodTitle(period, ns.Ledger.FirstDay())
  local inc, exp = ns.Ledger.Sum(period)
  local rows = {
    { kind = "title", text = title, sub = sub },
    { kind = "tiles", tiles = {
      { label = "Earned", value = ns.Money(inc), color = C.green },
      { label = "Spent", value = ns.Money(exp), color = C.red },
      { label = "Profit", value = ns.Signed(inc - exp), color = inc >= exp and C.gold or C.red },
    } },
  }
  local since = ns.PeriodStart(period)
  local shown, lastDay = 0, nil
  for _, e in ipairs(ns.db.ledger.recent) do
    if since and e.t < since then break end
    if shown >= MAX_ENTRIES then
      rows[#rows + 1] = { kind = "note", text = "Older entries are not shown." }
      break
    end
    local dayKey = date("%Y-%m-%d", e.t)
    if dayKey ~= lastDay then
      lastDay = dayKey
      rows[#rows + 1] = { kind = "section", text = DayLabel(e.t),
        right = T.Color("profit ", C.muted) .. ns.Signed(DayProfit(dayKey)) }
    end
    local note = date("%H:%M", e.t)
    if e.n then note = e.n .. (e.q and (" x" .. e.q) or "") .. "  ·  " .. note end
    rows[#rows + 1] = {
      kind = "row", icon = e.id and T.ItemIcon(e.id) or T.SourceIcon(e.s), itemID = e.id,
      label = ns.Ledger.SOURCE_LABELS[e.s] or e.s, note = note, value = ns.Signed(e.a),
    }
    shown = shown + 1
  end
  if shown == 0 then
    rows[#rows + 1] = { kind = "note", text = "No gold has moved " .. ns.PeriodPhrase(period) .. "." }
  end
  return rows
end

ns.RegisterTab({ key = "log", label = "Gold log", periods = true, render = Render })
