-- Cutpurse Ledger: core
-- Shared helpers, saved data, a small event bus and startup. Every other file
-- gets the same namespace table `ns` and adds its own part to it.

local ADDON, ns = ...

ns.GRACE_SECONDS = 1.5   -- loot/money events can arrive just after a loot window closes
ns.OPEN_TIMEOUT = 2.0    -- how long after a gathering cast we wait for the loot window
ns.CONTEXT_GRACE = 2.5   -- money from a trade/flight/etc. can arrive just after its window closes
ns.FLAG_TTL = 3.0        -- how long an action (repair, mail money, ...) waits for its money change
ns.HISTORY_DAYS = 7      -- days shown in the gathering tab
ns.RECENT_MAX = 300      -- gold log entries kept per character
ns.LOG_LINES = 24        -- gold log entries shown in the window

-- ns.acc = account-wide data, ns.db = this character's data, ns.ui = shared UI settings

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
-- Money as colored numbers with coin icons, skipping empty units:
-- 43g 2s 96c -> "43(g) 2(s) 96(c)", 50c -> "50(c)".
local COIN = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:1:0|t"
local GOLD, SILVER, COPPER = COIN:format("Gold"), COIN:format("Silver"), COIN:format("Copper")

local function Thousands(n)
  local s = tostring(n)
  while true do
    local k
    s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if k == 0 then return s end
  end
end

function ns.Money(copper)
  copper = math.floor(math.abs(copper or 0))
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = "|cffffd860" .. Thousands(g) .. "|r" .. GOLD end
  if s > 0 then parts[#parts + 1] = "|cffd8d8e0" .. s .. "|r" .. SILVER end
  if c > 0 or #parts == 0 then parts[#parts + 1] = "|cffe8a868" .. c .. "|r" .. COPPER end
  return table.concat(parts, " ")
end

function ns.Signed(copper)
  if copper > 0 then return "|cff5cdc75+|r" .. ns.Money(copper) end
  if copper < 0 then return "|cffff6b6b-|r" .. ns.Money(-copper) end
  return ns.Money(0)
end

function ns.Gold(s) return "|cffffd100" .. s .. "|r" end
function ns.Grey(s) return "|cff999999" .. s .. "|r" end

function ns.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Cutpurse Ledger:|r " .. msg)
end

function ns.SpellName(id)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(id)
    return info and info.name
  end
  return GetSpellInfo and (GetSpellInfo(id))
end

-- GetItemInfo moved to C_Item on modern clients (Forever has no global one).
function ns.ItemInfo(item)
  if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(item) end
  if GetItemInfo then return GetItemInfo(item) end
end

function ns.SellPrice(item)
  return select(11, ns.ItemInfo(item)) or 0
end

-- Name, quality, item class and binding for an item ID. If the game client hasn't
-- loaded the item yet, ask for it and return nil; ns.Refresh runs when it arrives.
-- classID: 0 consumable, 2 weapon, 4 armor, 7 trade goods, 12 quest, ...
-- bindType: 1 = binds when picked up (can't be traded)
local pendingItems = {}
function ns.ItemDetails(id)
  local name, _, quality, _, _, _, _, _, _, _, _, classID, _, bindType = ns.ItemInfo(id)
  if name then return { name = name, quality = quality, classID = classID, bindType = bindType } end
  if not pendingItems[id] and C_Item and C_Item.RequestLoadItemDataByID then
    pendingItems[id] = true
    C_Item.RequestLoadItemDataByID(id)
  end
  return nil
end

-- Current and max skill for a profession by name ("Skinning").
function ns.SkillRank(name)
  if not name then return end
  if GetProfessions and GetProfessionInfo then  -- modern clients (Forever)
    local ids = { GetProfessions() }
    for i = 1, 6 do
      if ids[i] then
        local n, _, rank, maxRank = GetProfessionInfo(ids[i])
        if n == name then return rank, maxRank end
      end
    end
  end
  if GetNumSkillLines and GetSkillLineInfo then  -- classic clients
    for i = 1, GetNumSkillLines() do
      local n, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
      if not isHeader and n == name then return rank, maxRank end
    end
  end
end

function ns.ContainerItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.hyperlink, info.stackCount end
  elseif GetContainerItemInfo then
    local _, count, _, _, _, _, link = GetContainerItemInfo(bag, slot)
    return link, count
  end
end

function ns.FormatDuration(seconds)
  seconds = math.floor(seconds)
  return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

function ns.DayKey(offsetDays)
  return date("%Y-%m-%d", time() - (offsetDays or 0) * 86400)
end

-- Turn a GlobalStrings format like "You receive loot: %sx%d." into a Lua pattern.
function ns.ToPattern(fmt)
  fmt = fmt:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
  fmt = fmt:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
  return "^" .. fmt .. "$"
end

-- Run fn after a global function is called (no-op if this client lacks it).
function ns.Hook(name, fn)
  if type(_G[name]) == "function" then hooksecurefunc(name, fn) end
end

---------------------------------------------------------------------------
-- Periods: every "how much did I make" view uses one of these
---------------------------------------------------------------------------
ns.PERIODS = {
  { key = "session", label = "Session" },
  { key = "today",   label = "Today",    days = 1 },
  { key = "week",    label = "7 days",   days = 7 },
  { key = "month",   label = "30 days",  days = 30 },
  { key = "all",     label = "All time" },
}
local PERIOD_BY_KEY = {}
for _, p in ipairs(ns.PERIODS) do PERIOD_BY_KEY[p.key] = p end

-- Number of calendar days in a period (nil for session / all time).
function ns.PeriodDays(period) return PERIOD_BY_KEY[period] and PERIOD_BY_KEY[period].days end

-- Session = since you logged in (or typed /cl session).
ns.sessionStart = GetTime()      -- for durations
ns.sessionStartTime = time()     -- for timestamps
local sessionResets = {}
function ns.OnSessionReset(fn) table.insert(sessionResets, fn) end
function ns.ResetSession()
  ns.sessionStart, ns.sessionStartTime = GetTime(), time()
  for _, fn in ipairs(sessionResets) do fn() end
end

-- Midnight, n days ago (0 = today).
function ns.DayStart(daysAgo)
  local t = date("*t", time() - (daysAgo or 0) * 86400)
  t.hour, t.min, t.sec = 0, 0, 0
  return time(t)
end

-- Unix time where a period starts (nil = no limit).
function ns.PeriodStart(period)
  if period == "session" then return ns.sessionStartTime end
  local days = ns.PeriodDays(period)
  if days then return ns.DayStart(days - 1) end
  return nil
end

local function ShortDate(t) return (date("%d %b", t):gsub("^0", "")) end
ns.ShortDate = ShortDate

-- Big, plain heading for a period, e.g. "Today  ·  Sun 22 Nov".
function ns.PeriodTitle(period, firstDay)
  if period == "session" then
    return "This session", "since you logged in, " .. ns.FormatDuration(GetTime() - ns.sessionStart) .. " ago"
  elseif period == "today" then
    return "Today", date("%A ") .. ShortDate(time())
  elseif period == "all" then
    return "All time", firstDay and ("since " .. firstDay) or "since Cutpurse Ledger was installed"
  end
  local days = ns.PeriodDays(period)
  return "Last " .. days .. " days", ShortDate(ns.DayStart(days - 1)) .. " - " .. ShortDate(time())
end

-- Heading line for a period, e.g. "TODAY   Sunday 22 Nov".
function ns.PeriodHeading(period, firstDay)
  local title, sub = ns.PeriodTitle(period, firstDay)
  return ns.Gold(title:upper()) .. "   " .. ns.Grey(sub)
end

-- "today", "in the last 7 days", ... for sentences like "Nothing earned today".
function ns.PeriodPhrase(period)
  if period == "session" then return "this session" end
  if period == "today" then return "today" end
  if period == "all" then return "yet" end
  return "in the last " .. ns.PeriodDays(period) .. " days"
end

-- Let the player drag a frame around; its position is saved in ns.ui[posKey].
function ns.MakeMovable(frame, posKey)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetClampedToScreen(true)
  frame:SetScript("OnDragStart", function(self) self.dragging = true; self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.ui[posKey] = { point, relPoint, x, y }
  end)
end

function ns.RestorePosition(frame, posKey, ...)
  frame:ClearAllPoints()
  local p = ns.ui[posKey]
  if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint(...) end
end

ns.BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

---------------------------------------------------------------------------
-- Event bus: any file can listen to any event
---------------------------------------------------------------------------
local handlers = {}
local bus = CreateFrame("Frame")
bus:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do fn(...) end
end)

function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    pcall(bus.RegisterEvent, bus, event)  -- skip events this client doesn't have
  end
  table.insert(handlers[event], fn)
end

-- Startup steps, run in file order once saved data is ready.
local initSteps = {}
function ns.OnInit(fn) table.insert(initSteps, fn) end

-- UI refreshers, run whenever data changes.
local refreshers = {}
function ns.OnRefresh(fn) table.insert(refreshers, fn) end
function ns.Refresh()
  if not ns.db then return end
  for _, fn in ipairs(refreshers) do fn() end
end

-- Item data arriving from the server: redraw once, shortly after the last one.
local itemRefreshQueued = false
ns.On("GET_ITEM_INFO_RECEIVED", function(itemID)
  if not pendingItems[itemID] then return end
  pendingItems[itemID] = nil
  if itemRefreshQueued then return end
  itemRefreshQueued = true
  C_Timer.After(0.5, function() itemRefreshQueued = false; ns.Refresh() end)
end)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
ns.On("PLAYER_LOGIN", function()
  LootLedgerAccountDB = LootLedgerAccountDB or {}
  local acc = LootLedgerAccountDB
  acc.chars = acc.chars or {}
  acc.ui = acc.ui or {}
  ns.acc, ns.ui = acc, acc.ui

  local name, realm = UnitName("player"), GetRealmName()
  local key = realm .. "-" .. name
  local ch = acc.chars[key]
  if not ch then ch = {}; acc.chars[key] = ch end
  ch.name, ch.realm, ch.class = name, realm, select(2, UnitClass("player"))
  -- Forever returns "" from GetRealmName; keep the key stable, but find a name to show.
  local shown = realm ~= "" and realm or (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
  ch.realmLabel = shown ~= "" and shown or nil
  ch.acts = ch.acts or {}
  ch.ledger = ch.ledger or { days = {}, recent = {} }
  ns.db = ch

  -- Move data from version 2.x (stored per character) into the account-wide store.
  local v2 = LootLedgerDB
  if v2 and v2.acts then
    for k, b in pairs(v2.acts) do
      if not ch.acts[k] then ch.acts[k] = b end
    end
    if v2.importedPickpocket then ch.importedPickpocket = true end
    if not ns.ui.boxPos then ns.ui.boxPos = v2.boxPos end
    if not ns.ui.winPos then ns.ui.winPos = v2.winPos end
    if ns.ui.boxShown == nil then ns.ui.boxShown = v2.boxShown end
  end
  LootLedgerDB = nil

  if ns.ui.boxShown == nil then ns.ui.boxShown = true end
  ns.ui.period = ns.ui.period or "today"
  ch.gold, ch.lastSeen = GetMoney(), time()

  for _, fn in ipairs(initSteps) do fn() end
  ns.Refresh()
  C_Timer.NewTicker(10, ns.Refresh)  -- keeps per-hour numbers fresh
end)
