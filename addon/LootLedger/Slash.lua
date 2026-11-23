-- Cutpurse Ledger: slash commands.

local ADDON, ns = ...
local G = ns.Gathering

SLASH_LOOTLEDGER1 = "/cutpurse"
SLASH_LOOTLEDGER2 = "/cl"
SLASH_LOOTLEDGER3 = "/ll"          -- old name, kept so existing habits work
SLASH_LOOTLEDGER4 = "/lootledger"
SLASH_LOOTLEDGER5 = "/pp"
SlashCmdList.LOOTLEDGER = function(msg)
  local raw = msg or ""  -- original text, item links intact
  msg = raw:lower():match("^%s*(.-)%s*$")
  if msg == "" then
    ns.OpenTab()
  elseif msg == "home" or msg == "overview" then
    ns.OpenTab("home")
  elseif msg == "earnings" or msg == "log" then
    ns.OpenTab("earnings", msg == "log" and "log" or "summary")
  elseif msg == "inventory" or msg == "inv" or msg == "sell" then
    ns.OpenTab("sell", msg == "sell" and "SELL" or "ALL")
  elseif msg == "trending" then
    ns.OpenTab("market", "hot")
  elseif G.BY_KEY[msg] or msg == "gathering" then
    ns.OpenTab("earnings", G.BY_KEY[msg] and msg or "summary")
  elseif msg:match("^market") then
    -- /cl market            -> open the tab
    -- /cl market <link>     -> that item (shift-click an item into the chat line)
    -- /cl market <name>     -> first item you've owned whose name contains the text
    local id = tonumber(raw:match("item:(%d+)"))
    local query = msg:match("^market%s+(.+)$")
    if not id and query then
      for itemID, it in pairs(ns.acc.items or {}) do
        if it.name and it.name:lower():find(query, 1, true) then id = itemID; break end
      end
      if not id then ns.Print("No item you've owned matches \"" .. query .. "\". Try shift-clicking an item link instead.") end
    end
    if id then ns.OpenMarket(id) else ns.OpenTab("market") end
  elseif msg == "debug mail" then
    -- What the game reports for each mail: checks the AH sale details we rely on.
    if not (GetInboxNumItems and GetInboxHeaderInfo) then ns.Print("Mail API not available.") return end
    local n = GetInboxNumItems()
    if n == 0 then ns.Print("Open your mailbox first (or it's empty).") return end
    for i = 1, n do
      local _, _, sender, subject, money = GetInboxHeaderInfo(i)
      ns.Print(("#%d from %s: %s  money %s"):format(i, tostring(sender), tostring(subject), ns.Money(money or 0)))
      if GetInboxInvoiceInfo then
        local v = { GetInboxInvoiceInfo(i) }
        if v[1] then
          ns.Print(("   invoice: type=%s item=%s bid=%s buyout=%s deposit=%s cut=%s count=%s"):format(
            tostring(v[1]), tostring(v[2]), tostring(v[4]), tostring(v[5]), tostring(v[6]), tostring(v[7]), tostring(v[11])))
          local inv = ns.Ledger.Invoice(i)
          if inv then ns.Print(("   read as: item id %s, %s units, net %s"):format(tostring(inv.sale), tostring(inv.n), ns.Money(inv.net))) end
        end
      end
      if GetInboxItem then
        for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
          local name, itemID, _, count = GetInboxItem(i, a)
          if name then ns.Print(("   item %d: %s (id %s) x%s"):format(a, name, tostring(itemID), tostring(count))) end
        end
      end
      if i >= 10 then ns.Print("(first 10 mails only)") break end
    end
  elseif msg == "debug trade" then
    -- Everything the trade record knows, and a cross-check against the gold log.
    local store = ns.Trade.Store()
    local soldNet, lost, sales, posts, units = 0, 0, 0, 0, 0
    for _, e in pairs(store.items) do
      soldNet, lost = soldNet + e.tot.soldNet - e.tot.vendNet, lost + e.tot.lostDep
      sales, units = sales + #e.sales, units + e.tot.ahN
      posts = posts + #e.posts
    end
    local logged = 0
    for k, day in pairs(ns.db.ledger.days) do
      if k >= date("%Y-%m-%d", store.since) and day.ah_sale then logged = logged + day.ah_sale.inc end
    end
    ns.Print(("Trade record since %s: %d sales (%d units), AH net %s, deposits lost %s, %d open postings, %d unmatched sale mails.")
      :format(date("%d %b %H:%M", store.since), sales, units, ns.Money(soldNet), ns.Money(lost), posts, #store.unmatched))
    ns.Print("Gold log AH sales since then (this character): " .. ns.Money(logged) .. ". Should match AH net above if only this character sells.")
    for _, u in ipairs(store.unmatched) do ns.Print("  unmatched: " .. tostring(u.name) .. " x" .. tostring(u.n) .. " " .. ns.Money(u.net or 0)) end
  elseif msg:match("^house") then
    -- /cl house          list the houses and which one this character uses
    -- /cl house <id>     use that house (stops automatic detection for this character)
    -- /cl house auto     go back to automatic detection (next time the AH opens)
    local arg = msg:match("^house%s+(%S+)")
    local id = tonumber(arg or "")
    local houses = ns.Prices.Houses()
    if #houses == 0 then
      ns.Print("No price data loaded. Install or update LootLedger_Prices and restart WoW.")
    elseif arg == "auto" then
      ns.db.house, ns.db.houseSource, ns.db.houseCheck = nil, nil, nil
      ns.Prices.ClearCache()
      ns.Refresh()
      ns.Print("Automatic detection is on. Open the auction house and your house is picked within a few seconds.")
      if ns.DetectHouse then ns.DetectHouse(true) end
    elseif id then
      local ok = false
      for _, h in ipairs(houses) do if h.id == id then ok = true end end
      if ok then
        ns.Prices.SetHouse(id, "manual")
        ns.Refresh()
        ns.Print("This character now uses auction house " .. id .. " for prices. (/cl house auto to detect it instead.)")
      else
        ns.Print("House " .. id .. " isn't in the price data. Type /cl house to see the options.")
      end
    else
      local current, _, how = ns.Prices.House()
      ns.Print(("This character uses house %s (%s). Houses in the price data:"):format(tostring(current),
        ({ detected = "detected at the AH", manual = "set by you", guess = "a guess until you open the AH" })[how] or "?"))
      local probe = { { 8170, "Rugged Leather" }, { 4304, "Thick Leather" }, { 14047, "Runecloth" } }
      for _, h in ipairs(houses) do
        local info = LootLedgerPrices.houses[h.id]
        local parts = {}
        for _, p in ipairs(probe) do
          local s = info.items[p[1]]
          local min = s and tonumber(s:match("^%d+,(%d+)"))
          parts[#parts + 1] = p[2] .. " " .. (min and ns.Money(min) or "-")
        end
        DEFAULT_CHAT_FRAME:AddMessage(("  |cffffd100%d|r %s%s  %s"):format(h.id, info.name or "", h.id == current and " |cff5cdc75(this character)|r" or "",
          table.concat(parts, ",  ")))
      end
      DEFAULT_CHAT_FRAME:AddMessage("  /cl house <number> to set it yourself, /cl house auto to detect it at the AH.")
    end
  elseif msg == "scan" then
    -- Scan the auction house you're at (open it first): prices as listed right now.
    ns.Scan.Start()
  elseif msg == "worth" or msg == "networth" then
    -- Gold on every character plus their items at current prices.
    local w = ns.Advisor.NetWorth()
    ns.Print(("Net worth %s: %s gold + %s in items (bags, bank, mail as of your last visit)."):format(
      ns.Money(w.total), ns.Money(w.gold), ns.Money(w.items)))
    for _, c in ipairs(w.chars) do
      DEFAULT_CHAT_FRAME:AddMessage(("  %s%s: %s  (gold %s, items %s)"):format(c.name,
        c.faction and (" (" .. c.faction .. ")") or "", ns.Money(c.total), ns.Money(c.gold), ns.Money(c.items)))
    end
    if w.unpriced > 0 then
      DEFAULT_CHAT_FRAME:AddMessage(("  %d item stacks have no AH price and count at their vendor price."):format(w.unpriced))
    end
  elseif msg == "box" then
    ns.ToggleBox()
  elseif msg == "session" then
    ns.ResetSession()
    ns.Refresh()
    ns.Print("Session reset (per-hour numbers start over).")
  elseif msg == "reset" then
    ns.db.acts = {}
    ns.db.ledger = { days = {}, recent = {} }
    ns.ResetSession()
    ns.Refresh()
    ns.Print("Everything on this character reset.")
  else
    ns.Print("/cl  open · /cl overview | log | inventory | sell | gathering | skinning | pickpocket | mining | herbalism · /cl trending · /cl market [item] · /cl worth · /cl scan · /cl house · /cl box · /cl session · /cl reset")
  end
end
