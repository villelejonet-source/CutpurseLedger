-- Cutpurse Ledger: Earnings tab. Everything about money made, for the chosen
-- period: Summary (earned / spent / sources, plus gathering by activity), one
-- subtab per activity (pickpocket, skinning, ...), and the full gold log.

local ADDON, ns = ...
local G = ns.Gathering
local V = ns.Views

local subtabs = { { key = "summary", label = "Summary" } }
for _, a in ipairs(G.ACTIVITIES) do subtabs[#subtabs + 1] = { key = a.key, label = a.label } end
subtabs[#subtabs + 1] = { key = "log", label = "Gold log" }

local function Render(sub, period)
  if sub == "log" then return V.log(nil, period) end
  if sub ~= "summary" then return V.gathering(sub, period) end

  -- Summary: the money overview, then gathering by activity (without repeating
  -- the period title and tiles).
  local rows = V.overview(nil, period)
  local gathering = V.gathering("summary", period)
  local start
  for i, r in ipairs(gathering) do
    if r.kind == "section" then start = i; break end
  end
  if start then
    rows[#rows + 1] = { kind = "space", h = 6 }
    rows[#rows + 1] = { kind = "section", text = "Gathering" }
    for i = start + 1, #gathering do rows[#rows + 1] = gathering[i] end
  end
  return rows
end

ns.RegisterTab({ key = "earnings", label = "Earnings", order = 2, periods = true, subtabs = subtabs, render = Render })
