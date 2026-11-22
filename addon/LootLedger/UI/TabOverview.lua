-- Loot Ledger: Overview tab.
-- Period heading, three big numbers (earned / spent / profit), where the money
-- came from and went (with bars), then "right now" gold and item worth.

local ADDON, ns = ...
local T = ns.Theme
local C = T.C

local function SortedSources(bySrc, field)
  local list = {}
  for s, e in pairs(bySrc) do
    if e[field] > 0 then list[#list + 1] = { s = s, v = e[field] } end
  end
  table.sort(list, function(x, y) return x.v > y.v end)
  return list
end

local function SourceRows(rows, list, total, color)
  for _, x in ipairs(list) do
    rows[#rows + 1] = {
      kind = "row", icon = T.SourceIcon(x.s), label = ns.Ledger.SOURCE_LABELS[x.s] or x.s,
      note = string.format("%d%%", math.floor(x.v / total * 100 + 0.5)),
      value = ns.Money(x.v), bar = x.v / list[1].v, barColor = color,
    }
  end
end

local function Render(_, period)
  local L = ns.Ledger
  local inc, exp, bySrc = L.Sum(period)
  local title, sub = ns.PeriodTitle(period, L.FirstDay())
  local profit = inc - exp
  local rows = {
    { kind = "title", text = title, sub = sub },
    { kind = "tiles", tiles = {
      { label = "Earned", value = ns.Money(inc), color = C.green },
      { label = "Spent", value = ns.Money(exp), color = C.red },
      { label = "Profit", value = ns.Signed(profit), color = profit >= 0 and C.gold or C.red },
    } },
  }

  if inc == 0 and exp == 0 then
    rows[#rows + 1] = { kind = "note", text = "No gold earned or spent " .. ns.PeriodPhrase(period) .. "." }
  else
    local income, spend = SortedSources(bySrc, "inc"), SortedSources(bySrc, "exp")
    if #income > 0 then
      rows[#rows + 1] = { kind = "section", text = "Earned from" }
      SourceRows(rows, income, inc, C.green)
    end
    if #spend > 0 then
      rows[#rows + 1] = { kind = "section", text = "Spent on" }
      SourceRows(rows, spend, exp, C.red)
    end
  end

  -- Right now (not affected by the period)
  rows[#rows + 1] = { kind = "section", text = "Right now", right = T.Color("not affected by the period", C.muted) }
  rows[#rows + 1] = { kind = "row", icon = T.GOLD_ICON, label = "Gold on " .. ns.db.name, value = ns.Money(GetMoney()) }
  local total, nChars = 0, 0
  for _, c in pairs(ns.acc.chars) do total, nChars = total + (c.gold or 0), nChars + 1 end
  if nChars > 1 then
    rows[#rows + 1] = { kind = "row", icon = T.GOLD_ICON, label = "Gold on all characters",
      note = nChars .. " characters", value = ns.Money(total) }
  end
  local worth, toSell, sellValue = 0, 0, 0
  for _, e in ipairs(ns.Advisor.InventoryPlan()) do
    worth = worth + e.total
    if e.decision.action == "SELL" then toSell, sellValue = toSell + 1, sellValue + e.total end
  end
  rows[#rows + 1] = { kind = "row", icon = T.BAG_ICON, label = "Your items are worth",
    note = "bags, bank and mail", value = ns.Money(worth) }
  if toSell > 0 then
    rows[#rows + 1] = { kind = "row", badge = { text = "Sell now", color = C.green },
      label = toSell .. (toSell == 1 and " item" or " items") .. " at a good price",
      note = "see Inventory", value = ns.Money(sellValue) }
  end
  return rows
end

ns.RegisterTab({ key = "overview", label = "Overview", periods = true, render = Render })
