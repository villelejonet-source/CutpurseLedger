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
  elseif msg == "overview" or msg == "log" or msg == "inventory" then
    ns.OpenTab(msg)
  elseif msg == "inv" or msg == "sell" then
    ns.OpenTab("inventory", msg == "sell" and "SELL" or nil)
  elseif G.BY_KEY[msg] or msg == "gathering" then
    ns.OpenTab("gathering", G.BY_KEY[msg] and msg)
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
    ns.Print("/cl  open · /cl overview | log | inventory | sell | gathering | skinning | pickpocket | mining | herbalism · /cl market [item] · /cl house · /cl box · /cl session · /cl reset")
  end
end
