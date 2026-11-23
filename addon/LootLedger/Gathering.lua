-- Cutpurse Ledger: gathering
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
    G.session[a.key] = { copper = 0, value = 0, count = 0, empty = 0, items = {}, lootV = {}, lootN = {} }
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
  b.lootV, b.lootN = b.lootV or {}, b.lootN or {}  -- added in 3.12
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
  d.lootV, d.lootN = d.lootV or {}, d.lootN or {}
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
  local t = { copper = 0, value = 0, count = 0, empty = 0, items = {}, lootV = {}, lootN = {} }
  for d = 0, ns.PeriodDays(period) - 1 do
    local day = b.days[ns.DayKey(d)]
    if day then
      t.copper, t.value = t.copper + day.copper, t.value + day.value
      t.count, t.empty = t.count + day.count, t.empty + day.empty
      for id, n in pairs(day.items or {}) do t.items[id] = (t.items[id] or 0) + n end
      for id, v in pairs(day.lootV or {}) do t.lootV[id] = (t.lootV[id] or 0) + v end
      for id, n in pairs(day.lootN or {}) do t.lootN[id] = (t.lootN[id] or 0) + n end
    end
  end
  return t
end

-- What a looted item is worth. Loot is valued at what YOU really get for it:
--   1. your own recent sales of that item (after the AH cut and lost deposits),
--   2. otherwise the AH price at the moment you looted it, after the 5% cut
--      (saved with the loot, so it doesn't follow the market), less your recent
--      share lost on failed listings (Trade.LossRate),
--   3. otherwise today's AH price after the cut (loot without a saved price).
-- Past days still change when your own sale price (1) or loss rate (2) changes.
-- See Trade.lua for how your own sale price is worked out.

local function Cut() return 1 - ((ns.Advisor and ns.Advisor.SETTINGS.ahCut) or 0.05) end

-- Today's AH price after the cut, per unit, or nil.
function G.NetNow(id)
  local p = ns.Prices and ns.Prices.Get(id)
  local ah = p and p.hasAH and ns.Prices.AHPrice(p)
  return ah and math.floor(ah * Cut()) or nil
end

-- Value of n units of one item from a G.Sum result (t holds the saved loot prices).
-- Returns value (or nil if nothing is known), info from ns.Trade.UnitValue.
function G.ItemValue(id, n, t)
  local fallback
  local ln = t and t.lootN and t.lootN[id]
  if ln and ln > 0 then fallback = t.lootV[id] / ln else fallback = G.NetNow(id) end
  local unit, info = ns.Trade.UnitValue(id, fallback)
  if not unit then return nil, info end
  info.unit = unit
  info.lootPrice = ln and ln > 0  -- the listing price is the one saved at loot time
  return unit * n, info
end

-- Worth of the items in a G.Sum result.
-- Returns total, units valued, units without any price, units valued from your own sales.
function G.ItemsValue(items, t)
  local total, priced, unpriced, fromSales = 0, 0, 0, 0
  for id, n in pairs(items or {}) do
    local v, info = G.ItemValue(id, n, t)
    if v then
      total, priced = total + v, priced + n
      if info.source == "sales" then fromSales = fromSales + n
      elseif info.source == "blend" then fromSales = fromSales + n * 0.5 end
    else
      unpriced = unpriced + n
    end
  end
  return math.floor(total + 0.5), priced, unpriced, fromSales
end

-- Total worth of a G.Sum result: gold looted + items (estimated, see above).
function G.Value(t)
  return t.copper + G.ItemsValue(t.items, t)
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
  local net = G.NetNow(id)  -- lock today's AH price (after the cut) to this loot
  b.items[id] = (b.items[id] or 0) + qty
  b.names[id] = link:match("%[(.-)%]") or b.names[id]
  b.value = b.value + worth
  local d = G.Day(b)
  d.value = d.value + worth
  d.items[id] = (d.items[id] or 0) + qty
  local s = G.session[key]
  s.value = s.value + worth
  s.items[id] = (s.items[id] or 0) + qty
  if net then
    for _, t in ipairs({ b, d, s }) do
      t.lootV[id] = (t.lootV[id] or 0) + net * qty
      t.lootN[id] = (t.lootN[id] or 0) + qty
    end
  end
  current.total = current.total + (net or 0) * qty  -- for "best single"
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
-- 3.12: loot from before has no saved price. Give it today's AH price once (after
-- the cut), so it stops moving with the market from now on. Only from a house we
-- know is yours (detected or set): a guessed house's prices would be locked in for
-- good. Until then lootPricesFrom stays unset, and this runs again at the next
-- login or when the house is set (Prices.SetHouse).
function G.LockOldLoot()
  if not ns.db or ns.db.lootPricesFrom then return end
  local status = ns.Prices and ns.Prices.Status()
  if not status or status.source == "none" then return end
  if status.source == "blizzard" and not status.confirmed then return end
  for key in pairs(ns.db.acts) do
    local b = G.Bucket(key)
    local function Lock(t)
      t.lootV, t.lootN = t.lootV or {}, t.lootN or {}
      for id, n in pairs(t.items or {}) do
        local have = t.lootN[id] or 0
        local net = n > have and G.NetNow(id)
        if net then
          t.lootV[id] = (t.lootV[id] or 0) + net * (n - have)
          t.lootN[id] = n
        end
      end
    end
    Lock(b)
    for _, d in pairs(b.days) do Lock(d) end
  end
  ns.db.lootPricesFrom = time()
end

ns.OnInit(function()
  G.LockOldLoot()
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
