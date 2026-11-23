-- Cutpurse Ledger: gold log
-- Every change in your money is recorded and labelled by what you were doing at
-- that moment: the window you had open (vendor, mailbox, AH, trainer, ...) or the
-- action you just took (Repair All, taking money from a mail, ...).

local ADDON, ns = ...
local L = {}
ns.Ledger = L

L.SOURCE_LABELS = {
  loot = "Mob loot", quest = "Quests",
  vendor_sell = "Vendor sales", vendor_buy = "Vendor purchases", repair = "Repairs",
  ah_sale = "AH sales", ah_refund = "AH outbid refunds", ah_deposit = "AH deposits", ah_buy = "AH purchases",
  mail_in = "Mail received", mail_out = "Mail sent & postage", trade = "Trades",
  training = "Training", flight = "Flights", bank = "Bank slots", other = "Other",
}
for _, a in ipairs(ns.Gathering.ACTIVITIES) do L.SOURCE_LABELS[a.key] = a.label end

-- Which way the money must move for an action flag to apply (+1 gain, -1 loss).
local FLAG_SIGN = {
  repair = -1, ah_deposit = -1, ah_buy = -1, flight = -1, training = -1, bank = -1,
  ah_sale = 1, ah_refund = 1, mail_in = 1, loot = 1,
}

local lastMoney = 0
local open, closedAt = {}, {}       -- which windows are open / when they closed
local flag                          -- last action waiting for its money change
local sellQueue, buyQueue = {}, {}  -- items handed to / bought from the vendor, oldest first

function L.SyncMoney() lastMoney = GetMoney() end
function L.IsOpen(ctx) return open[ctx] end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
-- Money moved since the session started, by source (not saved).
local session
local function ResetSession() session = { inc = 0, exp = 0, bySrc = {} } end
ResetSession()
ns.OnSessionReset(ResetSession)

local function AddTo(bySrc, s, inc, exp)
  local t = bySrc[s]
  if not t then t = { inc = 0, exp = 0 }; bySrc[s] = t end
  t.inc, t.exp = t.inc + inc, t.exp + exp
end

function L.Record(source, amount, item, qty)
  local ledger = ns.db.ledger
  local k = ns.DayKey()
  local day = ledger.days[k]
  if not day then day = {}; ledger.days[k] = day end
  local e = day[source]
  if not e then e = { inc = 0, exp = 0 }; day[source] = e end
  if amount > 0 then e.inc = e.inc + amount else e.exp = e.exp - amount end
  if amount > 0 then
    session.inc = session.inc + amount
    AddTo(session.bySrc, source, amount, 0)
  else
    session.exp = session.exp - amount
    AddTo(session.bySrc, source, 0, -amount)
  end

  local entry = { t = time(), a = amount, s = source }
  if item then
    entry.n = item:match("%[(.-)%]") or item
    entry.id = tonumber(item:match("item:(%d+)"))
    if qty and qty > 1 then entry.q = qty end
  end
  table.insert(ledger.recent, 1, entry)
  if #ledger.recent > ns.RECENT_MAX then table.remove(ledger.recent) end
end

-- Move an already recorded gain to another source (day totals, session and entry).
local function Relabel(entry, source)
  local day = ns.db.ledger.days[date("%Y-%m-%d", entry.t)]
  local old = day and day[entry.s]
  if old then
    old.inc = old.inc - entry.a
    if old.inc <= 0 and old.exp <= 0 then day[entry.s] = nil end
    AddTo(day, source, entry.a, 0)
  end
  if entry.t >= ns.sessionStartTime then
    local s = session.bySrc[entry.s]
    if s then s.inc = s.inc - entry.a end
    AddTo(session.bySrc, source, entry.a, 0)
  end
  entry.s = source
end

-- Income/expense for a list of day keys, total and by source.
local function SumDayKeys(keys)
  local inc, exp, bySrc = 0, 0, {}
  for _, k in ipairs(keys) do
    local day = ns.db.ledger.days[k]
    if day then
      for s, e in pairs(day) do
        AddTo(bySrc, s, e.inc, e.exp)
        inc, exp = inc + e.inc, exp + e.exp
      end
    end
  end
  return inc, exp, bySrc
end

-- Income/expense over the last n days (1 = today), total and by source.
function L.SumDays(n)
  local keys = {}
  for d = 0, n - 1 do keys[#keys + 1] = ns.DayKey(d) end
  return SumDayKeys(keys)
end

-- Income/expense for a period ("session", "today", "week", "month", "all").
function L.Sum(period)
  if period == "session" then return session.inc, session.exp, session.bySrc end
  local days = ns.PeriodDays(period)
  if days then return L.SumDays(days) end
  local keys = {}
  for k in pairs(ns.db.ledger.days) do keys[#keys + 1] = k end
  return SumDayKeys(keys)
end

-- Earliest day with any record, as a short date (for "All time · since ...").
function L.FirstDay()
  local first
  for k in pairs(ns.db.ledger.days) do if not first or k < first then first = k end end
  for _, b in pairs(ns.db.acts) do
    for k in pairs(b.days or {}) do if not first or k < first then first = k end end
  end
  if not first then return nil end
  local y, m, d = first:match("(%d+)-(%d+)-(%d+)")
  return ns.ShortDate(time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
end

function L.Flag(source, item, qty)
  flag = { source = source, item = item, qty = qty, expires = GetTime() + ns.FLAG_TTL }
end

local function Active(ctx)
  return open[ctx] or (closedAt[ctx] and GetTime() - closedAt[ctx] < ns.CONTEXT_GRACE)
end

-- Work out where a money change came from.
local function Classify(delta)
  local f = flag
  flag = nil
  if f and GetTime() < f.expires then
    local sign = FLAG_SIGN[f.source]
    if not sign or (sign > 0) == (delta > 0) then return f.source, f.item, f.qty end
  end
  if Active("trade") then return "trade" end
  if Active("merchant") then
    local item = table.remove(delta > 0 and sellQueue or buyQueue, 1)
    return delta > 0 and "vendor_sell" or "vendor_buy", item and item.link, item and item.qty
  end
  if Active("mail") then return delta > 0 and "mail_in" or "mail_out" end
  if Active("auction") then return delta > 0 and "ah_refund" or "ah_buy" end
  if Active("trainer") then return "training" end
  if Active("taxi") then return "flight" end
  if Active("bank") then return "bank" end
  if Active("loot") then return "loot" end
  return "other"
end

---------------------------------------------------------------------------
-- Hooks: actions that tell us what the next money change is for
---------------------------------------------------------------------------
local Flag, Hook = L.Flag, ns.Hook

local function OnUseContainerItem(bag, slot)
  if InRepairMode and InRepairMode() then Flag("repair"); return end
  if open.merchant then
    local link, count = ns.ContainerItem(bag, slot)
    if link then sellQueue[#sellQueue + 1] = { link = link, qty = count or 1 } end
  end
end
if C_Container and type(C_Container.UseContainerItem) == "function" then
  hooksecurefunc(C_Container, "UseContainerItem", OnUseContainerItem)
else
  Hook("UseContainerItem", OnUseContainerItem)
end

Hook("PickupInventoryItem", function() if InRepairMode and InRepairMode() then Flag("repair") end end)
Hook("RepairAllItems", function() Flag("repair") end)
Hook("BuyMerchantItem", function(index, qty)
  buyQueue[#buyQueue + 1] = { link = GetMerchantItemLink(index), qty = qty or 1 }
end)
Hook("BuybackItem", function(index)
  buyQueue[#buyQueue + 1] = { link = GetBuybackItemLink and GetBuybackItemLink(index), qty = 1 }
end)
Hook("GetQuestReward", function() Flag("quest") end)
Hook("TakeTaxiNode", function() Flag("flight") end)
Hook("BuyTrainerService", function() Flag("training") end)
Hook("PurchaseSlot", function() Flag("bank") end)
Hook("PostAuction", function() Flag("ah_deposit") end)
Hook("StartAuction", function() Flag("ah_deposit") end)
Hook("PlaceAuctionBid", function(listType, index)
  Flag("ah_buy", GetAuctionItemLink and GetAuctionItemLink(listType, index))
end)

local function OnMailTake(index)
  local invoiceType, itemName = nil, nil
  if GetInboxInvoiceInfo then invoiceType, itemName = GetInboxInvoiceInfo(index) end
  if invoiceType == "seller" then Flag("ah_sale", itemName); return end
  local sender = GetInboxHeaderInfo and select(3, GetInboxHeaderInfo(index))
  if sender and sender:find("Auction", 1, true) then Flag("ah_refund") else Flag("mail_in") end
end
Hook("TakeInboxMoney", OnMailTake)
Hook("AutoLootMailItem", OnMailTake)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
-- Window open/close events -> context name
local CONTEXT_EVENTS = {
  MERCHANT_SHOW = { "merchant", true },        MERCHANT_CLOSED = { "merchant", false },
  MAIL_SHOW = { "mail", true },                MAIL_CLOSED = { "mail", false },
  AUCTION_HOUSE_SHOW = { "auction", true },    AUCTION_HOUSE_CLOSED = { "auction", false },
  TRAINER_SHOW = { "trainer", true },          TRAINER_CLOSED = { "trainer", false },
  TAXIMAP_OPENED = { "taxi", true },           TAXIMAP_CLOSED = { "taxi", false },
  TRADE_SHOW = { "trade", true },              TRADE_CLOSED = { "trade", false },
  BANKFRAME_OPENED = { "bank", true },         BANKFRAME_CLOSED = { "bank", false },
  LOOT_OPENED = { "loot", true },              LOOT_CLOSED = { "loot", false },
}
for event, ctx in pairs(CONTEXT_EVENTS) do
  ns.On(event, function()
    open[ctx[1]] = ctx[2]
    if not ctx[2] then closedAt[ctx[1]] = GetTime() end
    if event == "MERCHANT_SHOW" then sellQueue, buyQueue = {}, {} end
  end)
end

ns.OnInit(L.SyncMoney)

ns.On("QUEST_TURNED_IN", function() Flag("quest") end)

-- "You loot 5 Silver, 20 Copper": money from a corpse, whether or not we saw
-- its loot window. The chat line can arrive before or after the money change.
ns.On("CHAT_MSG_MONEY", function()
  if not ns.db then return end
  local last = ns.db.ledger.recent[1]
  local recent = last and time() - last.t <= 3
  if recent and last.s == "other" and last.a > 0 then
    Relabel(last, "loot")      -- money came first and was unlabelled
    ns.Refresh()
  else
    Flag("loot")               -- money hasn't arrived yet
  end
end)

ns.On("PLAYER_MONEY", function()
  local now = GetMoney()
  local delta = now - lastMoney
  lastMoney = now
  if not ns.db or delta == 0 then return end
  ns.db.gold, ns.db.lastSeen = now, time()
  local activity = ns.Gathering.Current()
  if activity and delta > 0 then
    ns.Gathering.AddMoney(delta)
    L.Record(activity, delta)
  else
    local source, item, qty = Classify(delta)
    L.Record(source, delta, item, qty)
  end
  ns.Refresh()
end)
