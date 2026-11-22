-- Loot Ledger: gathering
-- When you cast a tracked spell (Pick Pocket, Skinning, ...), the next loot
-- window belongs to that activity. Money and items received while it is open
-- (plus a short grace period, for auto-loot) are credited to it.

local ADDON, ns = ...
local G = {}
ns.Gathering = G

G.ACTIVITIES = {
  { key = "pickpocket", label = "Pickpocket", spell = 921,  unit = "pockets" },
  { key = "skinning",   label = "Skinning",   spell = 8613, unit = "skins", skill = "Skinning" },
  { key = "mining",     label = "Mining",     spell = 2575, unit = "nodes", skill = "Mining" },
  { key = "herbalism",  label = "Herbalism",  spell = 2366, unit = "herbs", skill = "Herbalism" },
}
G.BY_KEY = {}
for _, a in ipairs(G.ACTIVITIES) do G.BY_KEY[a.key] = a end

G.session = {}
local function ResetSession()
  for _, a in ipairs(G.ACTIVITIES) do
    G.session[a.key] = { copper = 0, value = 0, count = 0, empty = 0, items = {} }
  end
end
ResetSession()
ns.OnSessionReset(ResetSession)

local spellToActivity = {}   -- spell name -> activity
local pending                -- { act, at } after a gathering cast
local current                -- gathering loot window being credited right now
local closeToken = 0

local LOOT_PATTERNS = {}
for _, g in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF" }) do
  if _G[g] then LOOT_PATTERNS[#LOOT_PATTERNS + 1] = ns.ToPattern(_G[g]) end
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
function G.Bucket(key)
  local b = ns.db.acts[key]
  if not b then
    b = { copper = 0, value = 0, count = 0, empty = 0, best = 0, items = {}, names = {}, days = {} }
    ns.db.acts[key] = b
  end
  return b
end

function G.Day(b)
  local k = ns.DayKey()
  local d = b.days[k]
  if not d then
    d = { copper = 0, value = 0, count = 0, empty = 0, items = {} }
    b.days[k] = d
  end
  d.items = d.items or {}  -- days saved before 3.3 have no item list
  return d
end

function G.PerHour(key)
  local elapsed = GetTime() - ns.sessionStart
  if elapsed < 60 then return nil end
  return math.floor(G.Value(G.session[key]) * 3600 / elapsed)
end

-- Totals for one activity over a period:
-- { copper, value, count, empty, items = { [id] = n }, best? }
function G.Sum(key, period)
  if period == "session" then return G.session[key] end
  local b = G.Bucket(key)
  if period == "all" then return b end
  local t = { copper = 0, value = 0, count = 0, empty = 0, items = {} }
  for d = 0, ns.PeriodDays(period) - 1 do
    local day = b.days[ns.DayKey(d)]
    if day then
      t.copper, t.value = t.copper + day.copper, t.value + day.value
      t.count, t.empty = t.count + day.count, t.empty + day.empty
      for id, n in pairs(day.items or {}) do t.items[id] = (t.items[id] or 0) + n end
    end
  end
  return t
end

-- Looted items are valued at their AH price only (TSM's latest price).
-- Items without an AH price count as 0 and are reported as "unpriced".
function G.ItemWorth(id)
  local p = ns.Prices and ns.Prices.Get(id)
  return p and ns.Prices.AHPrice(p) or nil
end

-- Worth of a set of looted items { [id] = n }.
-- Returns total, units with an AH price, units without one.
function G.ItemsValue(items)
  local total, priced, unpriced = 0, 0, 0
  for id, n in pairs(items or {}) do
    local worth = G.ItemWorth(id)
    if worth then total, priced = total + worth * n, priced + n
    else unpriced = unpriced + n end
  end
  return total, priced, unpriced
end

-- Total worth of a G.Sum result: gold looted + items at AH price.
-- (Days saved before 3.3 have no item list, so only their gold counts.)
function G.Value(t)
  return t.copper + G.ItemsValue(t.items)
end

-- The activity whose loot window is open right now, or nil.
function G.Current() return current and current.key end

function G.AddMoney(delta)
  local key = current.key
  local b = G.Bucket(key)
  b.copper = b.copper + delta
  local d = G.Day(b)
  d.copper = d.copper + delta
  G.session[key].copper = G.session[key].copper + delta
  current.total = current.total + delta
  current.got = true
end

local function AddItem(link, qty)
  local id = tonumber(link:match("item:(%d+)"))
  if not id then return end
  local key = current.key
  local b = G.Bucket(key)
  local worth = ns.SellPrice(link) * qty
  b.items[id] = (b.items[id] or 0) + qty
  b.names[id] = link:match("%[(.-)%]") or b.names[id]
  b.value = b.value + worth
  local d = G.Day(b)
  d.value = d.value + worth
  d.items[id] = (d.items[id] or 0) + qty
  local s = G.session[key]
  s.value = s.value + worth
  s.items[id] = (s.items[id] or 0) + qty
  current.total = current.total + (G.ItemWorth(id) or 0) * qty  -- for "best single"
  current.got = true
end

local function Finish()
  if not current then return end
  local key = current.key
  local b, s = G.Bucket(key), G.session[key]
  local d = G.Day(b)
  if current.got then
    b.count, d.count, s.count = b.count + 1, d.count + 1, s.count + 1
  else
    b.empty, d.empty, s.empty = b.empty + 1, d.empty + 1, s.empty + 1
  end
  if current.total > b.best then b.best = current.total end
  current = nil
  ns.Refresh()
end

---------------------------------------------------------------------------
-- Startup and events
---------------------------------------------------------------------------
ns.OnInit(function()
  for _, a in ipairs(G.ACTIVITIES) do
    local n = ns.SpellName(a.spell)
    if n then spellToActivity[n] = a end
  end

  -- One-time import from the old Pickpocket Tracker addon.
  local old = PickpocketTrackerDB
  if old and not ns.db.importedPickpocket then
    local b = G.Bucket("pickpocket")
    b.copper = b.copper + (old.copper or 0)
    b.count = b.count + (old.picks or 0)
    b.empty = b.empty + (old.empty or 0)
    b.best = math.max(b.best, old.best or 0)
    for k, d in pairs(old.days or {}) do
      b.days[k] = { copper = d.copper or 0, value = 0, count = d.picks or 0, empty = d.empty or 0 }
    end
    ns.db.importedPickpocket = true
    ns.Print("Imported " .. ns.Money(old.copper or 0) .. " from Pickpocket Tracker. You can delete that addon now.")
  end
end)

ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
  if unit ~= "player" or not spellID then return end
  local a = spellToActivity[ns.SpellName(spellID) or ""]
  if a then pending = { act = a, at = GetTime() } end
end)

ns.On("LOOT_OPENED", function()
  if pending and GetTime() - pending.at <= ns.OPEN_TIMEOUT then
    Finish()  -- previous loot still in its grace period
    current = { key = pending.act.key, total = 0, got = false }
    closeToken = closeToken + 1
    if ns.Ledger then ns.Ledger.SyncMoney() end
  end
  pending = nil
end)

ns.On("LOOT_CLOSED", function()
  if not current then return end
  closeToken = closeToken + 1
  local token = closeToken
  C_Timer.After(ns.GRACE_SECONDS, function()
    if token == closeToken then Finish() end
  end)
end)

ns.On("CHAT_MSG_LOOT", function(msg)
  if not current then return end
  for _, pat in ipairs(LOOT_PATTERNS) do
    local link, qty = msg:match(pat)
    if link then
      AddItem(link, tonumber(qty) or 1)
      ns.Refresh()
      return
    end
  end
end)
