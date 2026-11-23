-- Cutpurse Ledger: Sell tab. Everything you own on this realm (all
-- characters, bags + bank + mail), each with the advisor's decision.

local ADDON, ns = ...
local A = ns.Advisor
local T = ns.Theme
local C = T.C

local MAX_ROWS = 60
local FILTERS = {
  { key = "SELL",   label = "Sell now" },
  { key = "LIST",   label = "List" },
  { key = "HOLD",   label = "Hold" },
  { key = "CHECK",  label = "No price" },
  { key = "VENDOR", label = "Vendor" },
  { key = "ALL",    label = "All" },
}
local BADGE_COLORS = {
  SELL = C.green, LIST = C.gold, HOLD = C.blue, CHECK = { 1, 0.6, 0.2, 1 },
  VENDOR = { 0.75, 0.75, 0.75, 1 }, KEEP = C.muted,
}
local DESCRIPTIONS = {
  SELL = "Price is well above normal: post these on the AH now.",
  LIST = "Normal price: fine to post at market value.",
  HOLD = "Price is below normal: keep them and wait.",
  CHECK = "White or better, but there's no AH price for it yet. Don't vendor these: look it up on the AH first.",
  VENDOR = "Grey junk, soulbound items, and items the AH pays less for than a vendor.",
  ALL = "Everything you own on this realm.",
}

local function Render(filter)
  local plan = A.InventoryPlan()
  local rows = { { kind = "title", icon = T.BAG_ICON, text = "Sell",
    sub = "all your characters on this realm, right now" } }

  local sums = {}
  local worth = 0
  for _, e in ipairs(plan) do
    local k = e.decision.action
    sums[k] = (sums[k] or 0) + e.total
    worth = worth + e.total
  end
  rows[#rows + 1] = { kind = "tiles", tiles = {
    { label = "Worth", value = ns.Money(worth) },
    { label = "Sell now", value = ns.Money(sums.SELL or 0), color = C.green },
    { label = "Vendor", value = ns.Money(sums.VENDOR or 0), color = BADGE_COLORS.VENDOR },
  } }

  if ns.Prices.Status().source == "none" then
    rows[#rows + 1] = { kind = "note", text = ns.Prices.StatusText() }
  end

  local label = filter == "ALL" and "All items" or A.ACTIONS[filter].label
  local count = 0
  for _, e in ipairs(plan) do if filter == "ALL" or e.decision.action == filter then count = count + 1 end end
  rows[#rows + 1] = { kind = "section", text = label .. "  (" .. count .. ")",
    right = filter ~= "CHECK" and ns.Money(filter == "ALL" and worth or (sums[filter] or 0)) or nil }
  rows[#rows + 1] = { kind = "note", text = DESCRIPTIONS[filter] }

  local shown, best = 0, nil
  for _, e in ipairs(plan) do
    local d = e.decision
    if filter == "ALL" or d.action == filter then
      if shown >= MAX_ROWS then
        rows[#rows + 1] = { kind = "note", text = "More items not shown." }
        break
      end
      best = best or e.total
      local it = ns.acc.items[e.id] or {}
      rows[#rows + 1] = {
        kind = "row", icon = T.ItemIcon(e.id), itemID = e.id,
        badge = filter == "ALL" and { text = A.ACTIONS[d.action].label, color = BADGE_COLORS[d.action] } or nil,
        label = T.QualityText(e.name, it.quality) .. T.Color(" x" .. e.qty, C.muted),
        note = d.reason, value = d.action == "CHECK" and T.Color("?", C.muted) or ns.Money(e.total),
        bar = best and best > 0 and e.total / best or 0, barColor = BADGE_COLORS[d.action],
      }
      shown = shown + 1
    end
  end
  if shown == 0 then rows[#rows + 1] = { kind = "note", text = "Nothing here right now." } end

  local scanned = ns.db.inv and ns.db.inv.scanned or {}
  rows[#rows + 1] = { kind = "space", h = 6 }
  rows[#rows + 1] = { kind = "note", text = "Bank last seen " ..
    (scanned.bank and date("%d %b %H:%M", scanned.bank) or "never") ..
    "  ·  mailbox last seen " .. (scanned.mail and date("%d %b %H:%M", scanned.mail) or "never") }
  return rows
end

ns.RegisterTab({ key = "sell", label = "Sell", order = 3, subtabs = FILTERS, render = Render })
