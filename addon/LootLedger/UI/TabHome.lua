-- Cutpurse Ledger: Home tab. The first thing you see: what to do next with
-- your items (cards that jump to the right list), then how much you made in
-- the chosen period and where it came from.

local ADDON, ns = ...
local T = ns.Theme
local C = T.C

local function Plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

-- Items you own that are on a trending list right now (selling fast, price
-- climbing, drying up). Returns count, first item id, its list key.
local function TrendingOwned(owned)
  local t = ns.Prices.Trending()
  if not (t and t.ready) then return 0 end
  local n, firstID, firstList, seen = 0, nil, nil, {}
  for _, key in ipairs({ "hot", "climbing", "drying" }) do
    for _, e in ipairs(t.lists[key] or {}) do
      if owned[e.id] and not seen[e.id] then
        seen[e.id] = true
        n = n + 1
        firstID, firstList = firstID or e.id, firstList or key
      end
    end
  end
  return n, firstID, firstList
end

local function Cards()
  local count, total = {}, {}
  for _, e in ipairs(ns.Advisor.InventoryPlan()) do
    local k = e.decision.action
    count[k] = (count[k] or 0) + 1
    total[k] = (total[k] or 0) + e.total
  end
  local cards = {}
  cards[#cards + 1] = {
    label = "Sell now · " .. Plural(count.SELL or 0, "item"),
    value = (count.SELL or 0) > 0 and ns.Money(total.SELL) or "Nothing right now",
    color = C.green, onClick = function() ns.OpenTab("sell", "SELL") end,
  }
  local n, id, list = TrendingOwned(ns.Inventory.AllItems())
  local name = id and ((ns.acc.items[id] and ns.acc.items[id].name) or ns.ItemInfo(id))
  cards[#cards + 1] = {
    label = "Trending, you own · " .. n,
    value = name and (name .. (n > 1 and ("  +" .. (n - 1)) or "")) or "None right now",
    color = C.blue, onClick = function() ns.OpenTab("market", list or "hot") end,
  }
  cards[#cards + 1] = {
    label = "Vendor · " .. Plural(count.VENDOR or 0, "item"),
    value = ns.Money(total.VENDOR or 0),
    color = C.muted, onClick = function() ns.OpenTab("sell", "VENDOR") end,
  }
  cards[#cards + 1] = {
    label = "No AH price · check before vendoring",
    value = Plural(count.CHECK or 0, "item"),
    color = (count.CHECK or 0) > 0 and C.gold or C.muted, onClick = function() ns.OpenTab("sell", "CHECK") end,
  }
  return cards
end

local function Render(_, period)
  local rows = {
    { kind = "section", text = "Do this next" },
    { kind = "space", h = 6 },
    { kind = "cards", cards = Cards() },
  }

  -- Net worth: right now, all characters (not affected by the period)
  local w = ns.Advisor.NetWorth()
  rows[#rows + 1] = { kind = "section", text = "Net worth · all characters",
    right = T.Color("items at current prices", C.muted) }
  rows[#rows + 1] = { kind = "space", h = 6 }
  rows[#rows + 1] = { kind = "tiles", tiles = {
    { label = "Gold", value = ns.Money(w.gold), color = C.gold },
    { label = "Items", value = ns.Money(w.items), color = C.blue },
    { label = "Net worth", value = ns.Money(w.total), color = C.green },
  } }
  if #w.chars > 1 then
    for _, c in ipairs(w.chars) do
      rows[#rows + 1] = { kind = "row", icon = T.GOLD_ICON, label = c.name,
        note = (c.faction and (c.faction .. " · ") or "") .. ns.Money(c.gold) .. " gold",
        value = ns.Money(c.total), bar = w.chars[1].total > 0 and c.total / w.chars[1].total or 0, barColor = C.gold }
    end
  end
  if w.unpriced > 0 then
    rows[#rows + 1] = { kind = "note", text = w.unpriced .. " item stacks have no AH price and count at their vendor price. Bank and mail are as of your last visit." }
  end

  local L = ns.Ledger
  local inc, exp, bySrc = L.Sum(period)
  local title = ns.PeriodTitle(period, L.FirstDay())
  rows[#rows + 1] = { kind = "section", text = "Profit · " .. title }
  rows[#rows + 1] = { kind = "space", h = 6 }
  rows[#rows + 1] = { kind = "tiles", tiles = {
    { label = "Earned", value = ns.Money(inc), color = C.green },
    { label = "Spent", value = ns.Money(exp), color = C.red },
    { label = "Profit", value = ns.Signed(inc - exp), color = inc >= exp and C.gold or C.red },
  } }

  local list = {}
  for s, e in pairs(bySrc) do if e.inc > 0 then list[#list + 1] = { s = s, v = e.inc } end end
  table.sort(list, function(x, y) return x.v > y.v end)
  if #list == 0 then
    rows[#rows + 1] = { kind = "note", text = "No gold earned " .. ns.PeriodPhrase(period) .. "." }
  end
  for i = 1, math.min(3, #list) do
    local x = list[i]
    rows[#rows + 1] = { kind = "row", icon = T.SourceIcon(x.s), label = L.SOURCE_LABELS[x.s] or x.s,
      note = string.format("%d%%", math.floor(x.v / inc * 100 + 0.5)),
      value = ns.Money(x.v), bar = x.v / list[1].v, barColor = C.green }
  end
  -- What your gathering produced, valued at what you really get for it (not gold yet).
  local G = ns.Gathering
  local gathered = 0
  for _, a in ipairs(G.ACTIVITIES) do
    local t = G.Sum(a.key, period)
    gathered = gathered + G.ItemsValue(t.items, t)
  end
  if gathered > 0 then
    rows[#rows + 1] = { kind = "row", icon = T.BAG_ICON, label = "Gathered items (est.)",
      note = "not in Profit until sold", value = T.Color(ns.Money(gathered), C.muted) }
  end
  if #list > 3 then
    rows[#rows + 1] = { kind = "note", text = "Everything else, plus spending and gathering details: Earnings tab." }
  end
  return rows
end

ns.RegisterTab({ key = "home", label = "Home", order = 1, periods = true, render = Render })
