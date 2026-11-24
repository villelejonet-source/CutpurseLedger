-- Cutpurse Ledger: scan the auction house you're standing at.
-- The hourly feed can be hours old by the time it reaches the game. At the AH,
-- a scan reads every listing of your house in one go (C_AuctionHouse.ReplicateItems)
-- and gives prices as they are right now. Prices.Get uses a scan when it is
-- newer than the feed for that house.
--
-- Saved (account-wide, houses are shared by characters):
--   ns.acc.scans[house]          = { t, listings, items = { [itemID] = "market,min,qty" } }  latest scan
--   ns.acc.scanDays[house][day]  = { [itemID] = market }  last scan of each day, kept KEEP_DAYS days
-- house = the feed's house ID (0 without a feed). market follows the feed's rule:
-- the average of the cheapest 15% of units listed.
--
-- Unverified on WoW: Forever: that ReplicateItems exists, what it includes
-- (commodities?), and that GetReplicateItemInfo's buyout is for the whole stack.
-- Without the API, /cl scan says so and nothing else changes.

local ADDON, ns = ...
local S = {}
ns.Scan = S

S.THROTTLE = 15 * 60     -- Blizzard allows one full scan every 15 minutes
S.KEEP_DAYS = 14
S.CHUNK = 2000           -- listings read per frame, so the game doesn't freeze
S.MARKET_SHARE = 0.15    -- same rule as the feed (poller/ah.mjs)
S.TIMEOUT = 60           -- seconds to wait for the AH to answer

local state              -- nil, "waiting" (asked the AH) or "reading"
local scanHouse
-- Progress, for the button on the AH window and the Cutpurse Ledger header.
local progress = { done = 0, total = 0 }  -- listings read / listings to read
local startedAt                           -- GetTime() when the scan was asked for
local last                                -- how the last scan ended: { at, ok, listings, items, reason }

local function Changed()
  if S.UpdateButton then S.UpdateButton() end
  if ns.UpdateHeader then ns.UpdateHeader() end
end

-- Where the scan is: { state = "waiting"|"reading"|nil, done, total, pct (0..1),
-- waited (seconds since asked), last = how the previous scan ended (or nil) }
function S.Progress()
  local pct = progress.total > 0 and progress.done / progress.total or 0
  return { state = state, done = progress.done, total = progress.total, pct = pct,
    waited = startedAt and math.floor(GetTime() - startedAt) or 0, last = last }
end

-- One short line for the scan, or nil when nothing is going on.
function S.StatusLine()
  if state == "waiting" then return "asking the AH for every listing..." end
  if state == "reading" then return ("scanning AH %d%%"):format(math.floor(S.Progress().pct * 100)) end
end

local function Num(n)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end
S.Num = Num

function S.Supported()
  return C_AuctionHouse and C_AuctionHouse.ReplicateItems and C_AuctionHouse.GetNumReplicateItems
    and C_AuctionHouse.GetReplicateItemInfo and true or false
end

function S.Running() return state ~= nil end

-- The latest scan of a house (nil if none).
function S.Latest(house)
  return ns.acc and ns.acc.scans and ns.acc.scans[house or 0]
end

-- Seconds until the next scan is allowed (0 = now).
function S.Wait()
  return math.max(0, (ns.db and ns.db.lastScanAt or 0) + S.THROTTLE - time())
end

-- Per item: market (average of the cheapest MARKET_SHARE of units), lowest price, units.
-- rows[itemID] = { { unitPrice, qty }, ... }
function S.Summarize(rows)
  local items, n = {}, 0
  for id, r in pairs(rows) do
    table.sort(r, function(a, b) return a[1] < b[1] end)
    local qty = 0
    for _, x in ipairs(r) do qty = qty + x[2] end
    local want = math.max(1, math.ceil(qty * S.MARKET_SHARE))
    local taken, sum = 0, 0
    for _, x in ipairs(r) do
      local use = math.min(x[2], want - taken)
      sum, taken = sum + x[1] * use, taken + use
      if taken >= want then break end
    end
    items[id] = string.format("%d,%d,%d", math.floor(sum / taken + 0.5), math.floor(r[1][1] + 0.5), qty)
    n = n + 1
  end
  return items, n
end

local function Stopped(reason)
  state = nil
  last = { at = GetTime(), ok = false, reason = reason }
  Changed()
end

local function Finish(rows, listings)
  state = nil
  local items, n = S.Summarize(rows)
  last = { at = GetTime(), ok = n > 0, listings = listings, items = n,
    reason = n == 0 and "no listings with a buyout price" or nil }
  if n == 0 then Changed(); ns.Print("The scan found no listings with a buyout price.") return end
  ns.acc.scans = ns.acc.scans or {}
  ns.acc.scanDays = ns.acc.scanDays or {}
  ns.acc.scans[scanHouse] = { t = time(), listings = listings, n = n, items = items }

  local days = ns.acc.scanDays[scanHouse] or {}
  ns.acc.scanDays[scanHouse] = days
  local today = {}
  for id, s in pairs(items) do today[id] = tonumber(s:match("^(%d+)")) end
  days[ns.DayKey()] = today
  local oldest = ns.DayKey(S.KEEP_DAYS - 1)
  for k in pairs(days) do if k < oldest then days[k] = nil end end

  ns.Prices.ClearCache()
  ns.Refresh()
  Changed()
  ns.Print(("Scan done: %d listings, %d items. Prices for this auction house are now as of %s.")
    :format(listings, n, date("%H:%M")))
end

-- Read the listings a few thousand per frame.
local function Read()
  local total = C_AuctionHouse.GetNumReplicateItems() or 0
  local rows, i = {}, 0
  progress.done, progress.total = 0, total
  Changed()
  local function Step()
    if state ~= "reading" then return end
    local last = math.min(total - 1, i + S.CHUNK - 1)
    for k = i, last do
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(k)
      if itemID and buyout and buyout > 0 and count and count > 0 then
        local r = rows[itemID]
        if not r then r = {}; rows[itemID] = r end
        r[#r + 1] = { buyout / count, count }
      end
    end
    i = last + 1
    progress.done = i
    if i < total then Changed(); C_Timer.After(0, Step) else Finish(rows, total) end
  end
  Step()
end

-- Start a scan. Returns true if it started; otherwise says why in chat.
function S.Start()
  if not S.Supported() then
    ns.Print("This game client can't scan the whole auction house at once.")
    return false
  end
  if not ns.Ledger.IsOpen("auction") then ns.Print("Open the auction house first, then scan.") return false end
  if state then ns.Print("A scan is already running.") return false end
  local wait = S.Wait()
  if wait > 0 then
    ns.Print(("The auction house allows one full scan every 15 minutes. Try again in %d min."):format(math.ceil(wait / 60)))
    return false
  end
  state, scanHouse = "waiting", ns.Prices.House() or 0
  progress.done, progress.total, startedAt = 0, 0, GetTime()
  ns.db.lastScanAt = time()
  C_AuctionHouse.ReplicateItems()
  ns.Print("Scanning the auction house...")
  Changed()
  C_Timer.After(S.TIMEOUT, function()
    if state == "waiting" then
      Stopped("the auction house didn't answer")
      ns.Print("The auction house didn't answer the scan. Try again in a few minutes.")
    end
  end)
  return true
end

ns.On("REPLICATE_ITEM_LIST_UPDATE", function()
  if state ~= "waiting" then return end
  state = "reading"
  Read()
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  if state then Stopped("the auction house closed"); ns.Print("Scan stopped: the auction house closed.") end
end)

-- A "Scan" button on the auction house window (modern AH frame), made once.
-- The window is load-on-demand: on the first visit it may not exist yet when
-- AUCTION_HOUSE_SHOW reaches us, so we also try when Blizzard's AH UI finishes
-- loading, and once more on the next frame.
local button
local DONE_SHOWN = 8  -- seconds "Scan done" stays on the button

-- What the button shows: text, how full its bar is (0..1) and the bar's colour.
function S.ButtonState()
  local p = S.Progress()
  if p.state == "waiting" then
    return ("Asking AH... %ds"):format(p.waited), 0.04, { 1, 0.82, 0 }
  elseif p.state == "reading" then
    return ("Scanning %d%%"):format(math.floor(p.pct * 100)), p.pct, { 1, 0.82, 0 }
  end
  if p.last and GetTime() - p.last.at < DONE_SHOWN then
    if p.last.ok then return "Scan done", 1, { 0.36, 0.86, 0.46 } end
    return "Scan stopped", 1, { 1, 0.42, 0.42 }
  end
  local wait = S.Wait()
  if wait > 0 then return ("Scan in %d min"):format(math.ceil(wait / 60)), 0, nil end
  return "Cutpurse scan", 0, nil
end

function S.UpdateButton()
  if not button then return end
  local text, fill, color = S.ButtonState()
  button:SetText(text)
  local w = math.max(0, (button:GetWidth() or 0) - 8)
  button.fill:SetShown(fill > 0)
  if fill > 0 then
    button.fill:SetWidth(math.max(1, w * math.min(1, fill)))
    button.fill:SetColorTexture(color[1], color[2], color[3], 0.35)
  end
end

local function AddButton()
  if button or not S.Supported() or not AuctionHouseFrame then return end
  -- Named, so /run print(CutpurseLedgerScanButton:IsVisible()) can check it in game.
  button = CreateFrame("Button", "CutpurseLedgerScanButton", AuctionHouseFrame, "UIPanelButtonTemplate")
  S.button = button
  button:SetSize(130, 22)
  -- Below the window, right of the Buy / Sell / Auctions tabs: free space. On the
  -- title bar it was hidden behind the window's own border and title frames.
  button:SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, -2)
  button:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 20)
  button:SetText("Cutpurse scan")
  -- Progress bar inside the button, filling left to right while the scan reads.
  button.fill = button:CreateTexture(nil, "OVERLAY")
  button.fill:SetPoint("TOPLEFT", 4, -4)
  button.fill:SetPoint("BOTTOMLEFT", 4, 4)
  button.fill:Hide()
  local tick = 0
  button:SetScript("OnUpdate", function(_, elapsed)
    tick = tick + elapsed
    if tick >= 0.25 then tick = 0; S.UpdateButton() end  -- "Asking AH... 12s", cooldown minutes
  end)
  button:SetScript("OnClick", function() S.Start() end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Cutpurse Ledger: scan this auction house")
    GameTooltip:AddLine("Reads every listing now, so prices are up to the minute.", 0.8, 0.8, 0.8)
    local p = S.Progress()
    if p.state == "waiting" then
      GameTooltip:AddLine(("Waiting for the auction house to send its listings (%ds, gives up after %ds)."):format(p.waited, S.TIMEOUT), 1, 0.82, 0)
    elseif p.state == "reading" then
      GameTooltip:AddLine(("Reading listings: %s of %s (%d%%)"):format(Num(p.done), Num(p.total), math.floor(p.pct * 100)), 1, 0.82, 0)
    end
    local latest = S.Latest(ns.Prices.House() or 0)
    if latest then
      GameTooltip:AddLine(("Last scan %s: %s listings, %s items."):format(ns.Ago and ns.Ago(time() - latest.t) or date("%H:%M", latest.t),
        Num(latest.listings or 0), Num(latest.n or (function() local c = 0 for _ in pairs(latest.items or {}) do c = c + 1 end return c end)())), 0.8, 0.8, 0.8)
    end
    if p.last and not p.last.ok and not p.state then
      GameTooltip:AddLine("Last try stopped: " .. p.last.reason .. ".", 1, 0.42, 0.42)
    end
    local wait = S.Wait()
    if wait > 0 and not p.state then GameTooltip:AddLine(("Next scan possible in %d min."):format(math.ceil(wait / 60)), 1, 0.6, 0.2) end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
  AddButton()
  if not button then C_Timer.After(0, function() AddButton(); S.UpdateButton() end) end
  S.UpdateButton()
end)
ns.On("ADDON_LOADED", function(name)
  if name == "Blizzard_AuctionHouseUI" then AddButton() end
end)
