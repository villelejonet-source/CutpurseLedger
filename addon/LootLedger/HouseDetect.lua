-- Loot Ledger: find out which auction house this character uses.
--
-- The price data covers every auction house of the region, and the game doesn't
-- say which one you're standing at. So when the AH opens, we ask it about a few
-- common items whose quantity and price differ a lot between houses, compare the
-- answers with each house in the data, and keep the clear winner.
-- Runs at most once a day per character (and again if the result was unclear).

local ADDON, ns = ...
local P = ns.Prices

local PROBES = 5            -- items to ask about
local MIN_LISTED = 40       -- only items with a real market in every house
local QUERY_GAP = 1.0       -- seconds between searches, to stay well under the AH throttle
local REDETECT_DAYS = 1

local running, results, queue, timer
local function Feed() return type(LootLedgerPrices) == "table" and LootLedgerPrices or nil end

local function Supported()
  return C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey
    and C_AuctionHouse.GetCommoditySearchResultsQuantity and C_AuctionHouse.GetCommoditySearchResultInfo
end

-- Pick items that tell the houses apart: listed in every house, with the
-- biggest spread in quantity between houses.
local function PickProbes(feed)
  local houses = {}
  for id, h in pairs(feed.houses) do houses[#houses + 1] = h end
  if #houses < 2 then return {} end
  local scored = {}
  for itemID, s in pairs(houses[1].items) do
    local lo, hi, ok = math.huge, 0, true
    for _, h in ipairs(houses) do
      local v = h.items[itemID]
      local qty = v and tonumber(v:match("^%d+,%d+,(%d+)"))
      if not qty or qty < MIN_LISTED then ok = false; break end
      lo, hi = math.min(lo, qty), math.max(hi, qty)
    end
    if ok then scored[#scored + 1] = { id = itemID, spread = hi / lo } end
  end
  table.sort(scored, function(a, b) return a.spread > b.spread end)
  local out = {}
  for i = 1, math.min(PROBES, #scored) do out[i] = scored[i].id end
  return out
end

local function Finish()
  running = false
  if timer then timer:Cancel(); timer = nil end
  local feed = Feed()
  if not feed or #results == 0 then return end

  -- Lower score = closer match. Quantity counts most; lowest price helps break ties.
  local scores = {}
  for houseID, h in pairs(feed.houses) do
    local score, n = 0, 0
    for _, r in ipairs(results) do
      local v = h.items[r.id]
      if v then
        local _, min, qty = v:match("^(%d+),(%d+),(%d+)")
        score = score + math.abs(math.log((r.qty + 1) / (tonumber(qty) + 1)))
        if r.min and tonumber(min) > 0 then score = score + 0.5 * math.abs(math.log(r.min / tonumber(min))) end
        n = n + 1
      else
        score = score + 3
      end
    end
    scores[#scores + 1] = { id = houseID, score = score / math.max(1, #results) }
  end
  table.sort(scores, function(a, b) return a.score < b.score end)
  local best, second = scores[1], scores[2]
  local clear = best and (not second or best.score < second.score * 0.5) and best.score < 0.6
  ns.db.houseCheck = { at = time(), clear = clear and true or false }
  if not clear then return end

  local current, _, how = P.House()
  if how == "manual" and current ~= best.id then
    ns.Print(("This AH looks like house %d, but you set house %d. Type /ll house %d to switch."):format(best.id, current, best.id))
    return
  end
  if current ~= best.id or how ~= "detected" then
    P.SetHouse(best.id, "detected")
    local h = feed.houses[best.id]
    ns.Print(("Prices now use your auction house: %s %d (detected)."):format(h.name or "house", best.id))
    ns.Refresh()
  end
end

local function Next()
  local itemID = table.remove(queue, 1)
  if not itemID then Finish(); return end
  local ok = pcall(C_AuctionHouse.SendSearchQuery, C_AuctionHouse.MakeItemKey(itemID),
    { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, false)
  if not ok then Finish(); return end
  -- If no answer arrives, move on anyway.
  timer = C_Timer.NewTimer(QUERY_GAP * 4, Next)
end

ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
  if not running or not itemID then return end
  local wanted = false
  for _, r in ipairs(results) do if r.id == itemID then return end end  -- already have it
  for _, id in ipairs(running) do if id == itemID then wanted = true end end
  if not wanted then return end
  local qty = C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) or 0
  local first = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
  results[#results + 1] = { id = itemID, qty = qty, min = first and first.unitPrice }
  if timer then timer:Cancel() end
  timer = C_Timer.NewTimer(QUERY_GAP, Next)
end)

function ns.DetectHouse(force)
  if running or not Supported() then return false end
  local feed = Feed()
  if not feed or not ns.db then return false end
  local check = ns.db.houseCheck
  if not force and check and check.clear and time() - check.at < REDETECT_DAYS * 86400 then return false end
  local probes = PickProbes(feed)
  if #probes == 0 then return false end
  running, results, queue = probes, {}, { unpack(probes) }
  C_Timer.After(1.5, Next)  -- let the AH window finish opening first
  return true
end

ns.On("AUCTION_HOUSE_SHOW", function() ns.DetectHouse(false) end)
ns.On("AUCTION_HOUSE_CLOSED", function()
  if running then running = false; if timer then timer:Cancel(); timer = nil end end
end)
