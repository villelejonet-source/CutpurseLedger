-- Cutpurse Ledger: main window
-- Tabs are registered from other files with ns.RegisterTab, so new tabs can be
-- added without touching this file:
--
--   ns.RegisterTab({
--     key = "market", label = "Market",
--     order = 4,                                      -- position in the tab row
--     subtabs = { { key = "a", label = "A" }, ... },  -- optional: a row of subtabs
--     periods = true,                                 -- optional: period dropdown (Session/Today/...)
--     choices = function(subKey) return list, id end, -- optional: a dropdown of { key, label } instead,
--                                                     --   remembered per id (e.g. "range", "filter")
--     render = function(subKey, period, choiceKey) return rows end,
--   })
--
-- render returns a list of row specs, drawn top to bottom:
--   { kind = "title",   text = "Today", sub = "Sunday 22 Nov", icon = tex }
--   { kind = "tiles",   tiles = { { label = "EARNED", value = "...", color = C.green }, ... } }
--   { kind = "section", text = "Earned from", right = "optional text" }
--   { kind = "row",     icon = tex, label = "AH sales", note = "grey text", value = "...",
--                       bar = 0..1, barColor = C.gold, badge = { text = "Sell", color = C.green } }
--   { kind = "note",    text = "small grey text, wraps" }
--   { kind = "cards",   cards = { { label = "Sell now", value = "...", color = C.green, onClick = fn }, ... } }
--   { kind = "chart",   values = {...}, labels = {...}, format = fn, height = 150 }  (line chart)
--   { kind = "bars",    bars = { { label, value, text, color }, ... }, height = 120 }  (bars around zero)
--   { kind = "space",   h = 8 }

local ADDON, ns = ...
local T = ns.Theme
local C = T.C

local WIDTH, HEIGHT = 520, 600
local PAD = 16
local BODY_W = WIDTH - PAD * 2
local tabs, tabByKey = {}, {}
ns.Views = {}  -- page renderers that tabs combine (see TabEarnings, TabMarket)
local mainTab
local selectedSub = {}       -- tab key -> selected subtab key
local selectedChoice = {}    -- tab key -> { dropdown id -> selected key }
local mainButtons, subButtons = {}, {}

function ns.RegisterTab(tab)
  tabs[#tabs + 1] = tab
  tabByKey[tab.key] = tab
  if tab.subtabs then selectedSub[tab.key] = tab.subtabs[1].key end
  if not mainTab or (tab.order or 99) < (tabByKey[mainTab].order or 99) then mainTab = tab.key end
end
function ns.GetTab(key) return tabByKey[key] end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local win = CreateFrame("Frame", "LootLedgerWindow", UIParent)
ns.window = win
win:SetSize(WIDTH, HEIGHT)
win:SetFrameStrata("DIALOG")
win:Hide()
T.Panel(win)
tinsert(UISpecialFrames, "LootLedgerWindow")  -- Escape closes it

-- Header
local header = CreateFrame("Frame", nil, win)
header:SetPoint("TOPLEFT", 1, -1)
header:SetPoint("TOPRIGHT", -1, -1)
header:SetHeight(44)
T.Fill(header, "BACKGROUND", C.header, 1):SetAllPoints()
local headerLine = T.Fill(header, "BORDER", C.border)
headerLine:SetHeight(1)
headerLine:SetPoint("BOTTOMLEFT"); headerLine:SetPoint("BOTTOMRIGHT")

local logo = T.Icon(header, 26)
logo:SetPoint("LEFT", 12, 0)
logo:SetTexture(T.GOLD_ICON)
local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 10, 1)
title:SetText("Cutpurse Ledger")
local subtitle = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
subtitle:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

local close = CreateFrame("Button", nil, header)
close:SetSize(28, 28)
close:SetPoint("RIGHT", -8, 0)
local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
closeText:SetPoint("CENTER")
closeText:SetText("x")
closeText:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
close:SetScript("OnEnter", function() closeText:SetTextColor(C.text[1], C.text[2], C.text[3]) end)
close:SetScript("OnLeave", function() closeText:SetTextColor(C.muted[1], C.muted[2], C.muted[3]) end)
close:SetScript("OnClick", function() win:Hide() end)

-- Footer
local footer = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
footer:SetPoint("BOTTOMLEFT", PAD, 10)
footer:SetText("Session = since you logged in  ·  /cl session starts a new one")

-- Scrollable body
local scroll = CreateFrame("ScrollFrame", nil, win)
scroll:SetPoint("BOTTOMRIGHT", -PAD, 28)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(BODY_W, 10)
scroll:SetScrollChild(content)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
  local max = math.max(0, content:GetHeight() - self:GetHeight())
  self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
end)

---------------------------------------------------------------------------
-- Row widgets, pooled per kind
---------------------------------------------------------------------------
local pools = {}
local function Acquire(kind, make)
  local p = pools[kind]
  if not p then p = { list = {}, used = 0 }; pools[kind] = p end
  p.used = p.used + 1
  local f = p.list[p.used]
  if not f then f = make(); p.list[p.used] = f end
  f:Show()
  return f
end
local function ReleaseAll()
  for _, p in pairs(pools) do
    for i = 1, #p.list do p.list[i]:Hide() end
    p.used = 0
  end
end

local function SetTextColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local MAKE, HEIGHTS = {}, {}

function MAKE.title()
  local f = CreateFrame("Frame", nil, content)
  f.icon = T.Icon(f, 22)
  f.icon:SetPoint("LEFT", 0, 0)
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  SetTextColor(f.sub, C.muted)
  return f
end
HEIGHTS.title = 32
local function DrawTitle(f, r)
  f.icon:SetShown(r.icon ~= nil)
  if r.icon then f.icon:SetTexture(r.icon) end
  f.text:ClearAllPoints()
  f.text:SetPoint("LEFT", r.icon and 30 or 0, 0)
  f.text:SetText(r.text)
  f.sub:ClearAllPoints()
  f.sub:SetPoint("BOTTOMLEFT", f.text, "BOTTOMRIGHT", 10, 1)
  f.sub:SetText(r.sub or "")
end

function MAKE.tiles()
  local f = CreateFrame("Frame", nil, content)
  f.tiles = {}
  for i = 1, 4 do
    local t = CreateFrame("Frame", nil, f)
    t.bg = T.Fill(t, "BACKGROUND", C.panel); t.bg:SetAllPoints()
    t.accent = T.Fill(t, "ARTWORK", C.gold)
    t.accent:SetPoint("TOPLEFT"); t.accent:SetPoint("TOPRIGHT"); t.accent:SetHeight(2)
    t.label = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.label:SetPoint("TOPLEFT", 10, -10)
    SetTextColor(t.label, C.muted)
    t.value = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    t.value:SetPoint("BOTTOMLEFT", 10, 10)
    f.tiles[i] = t
  end
  return f
end
HEIGHTS.tiles = 66
local function DrawTiles(f, r)
  local n, gap = #r.tiles, 8
  local w = (BODY_W - gap * (n - 1)) / n
  for i, t in ipairs(f.tiles) do
    local spec = r.tiles[i]
    t:SetShown(spec ~= nil)
    if spec then
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", (i - 1) * (w + gap), 0)
      t:SetSize(w, HEIGHTS.tiles - 8)
      T.SetColor(t.accent, spec.color or C.gold)
      t.label:SetText(spec.label:upper())
      t.value:SetText(spec.value)
    end
  end
end

function MAKE.section()
  local f = CreateFrame("Frame", nil, content)
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.text:SetPoint("BOTTOMLEFT", 0, 5)
  SetTextColor(f.text, C.gold)
  f.right = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.right:SetPoint("BOTTOMRIGHT", 0, 5)
  f.line = T.Fill(f, "ARTWORK", C.line)
  f.line:SetHeight(1)
  f.line:SetPoint("BOTTOMLEFT", 0, 0)
  f.line:SetPoint("BOTTOMRIGHT", 0, 0)
  return f
end
HEIGHTS.section = 30
local function DrawSection(f, r)
  f.text:SetText(r.text:upper())
  f.right:SetText(r.right or "")
end

function MAKE.row()
  local f = CreateFrame("Frame", nil, content)
  f.stripe = T.Fill(f, "BACKGROUND", C.stripe); f.stripe:SetAllPoints()
  f.bar = T.Fill(f, "BORDER", C.gold)
  f.bar:SetPoint("TOPLEFT"); f.bar:SetPoint("BOTTOMLEFT")
  f.icon = T.Icon(f, 18)
  f.icon:SetPoint("LEFT", 4, 0)
  f.badge = CreateFrame("Frame", nil, f)
  f.badge:SetHeight(16)
  f.badge.bg = T.Fill(f.badge, "BACKGROUND", C.panel); f.badge.bg:SetAllPoints()
  f.badge.text = f.badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.badge.text:SetPoint("CENTER")
  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.label:SetJustifyH("LEFT")
  if f.label.SetWordWrap then f.label:SetWordWrap(false) end
  f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.value:SetPoint("RIGHT", -6, 0)
  f.value:SetJustifyH("RIGHT")
  f.hover = T.Fill(f, "BACKGROUND", C.line, 1)
  f.hover:SetAllPoints()
  f.hover:Hide()
  f:SetScript("OnEnter", function(self)
    self.hover:Show()
    if self.itemID then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.itemID)
      GameTooltip:Show()
    end
  end)
  f:SetScript("OnLeave", function(self) self.hover:Hide(); GameTooltip:Hide() end)
  -- Clicking an item row opens its price history
  f:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and self.itemID and ns.OpenMarket then ns.OpenMarket(self.itemID) end
  end)
  return f
end
HEIGHTS.row = 24
local function DrawRow(f, r, index)
  f.stripe:SetShown(index % 2 == 1)
  f.itemID = r.itemID
  f:EnableMouse(r.itemID ~= nil)
  if r.bar and r.bar > 0 then
    f.bar:Show()
    f.bar:SetWidth(math.max(2, math.min(1, r.bar) * BODY_W))
    T.SetColor(f.bar, r.barColor or C.gold, 0.16)
  else
    f.bar:Hide()
  end
  f.icon:SetShown(r.icon ~= nil)
  if r.icon then f.icon:SetTexture(r.icon) end
  local x = r.icon and 30 or 8
  if r.badge then
    f.badge:Show()
    f.badge.text:SetText(r.badge.text)
    SetTextColor(f.badge.text, r.badge.color)
    T.SetColor(f.badge.bg, r.badge.color, 0.18)
    f.badge:SetWidth(f.badge.text:GetStringWidth() + 12)
    f.badge:ClearAllPoints()
    f.badge:SetPoint("LEFT", x, 0)
    x = x + f.badge:GetWidth() + 8
  else
    f.badge:Hide()
  end
  f.label:ClearAllPoints()
  f.label:SetPoint("LEFT", x, 0)
  f.label:SetPoint("RIGHT", f.value, "LEFT", -10, 0)
  local label = r.label or ""
  if r.note then label = label .. "  " .. T.Color(r.note, C.muted) end
  f.label:SetText(label)
  f.value:SetText(r.value or "")
end

function MAKE.note()
  local f = CreateFrame("Frame", nil, content)
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.text:SetPoint("TOPLEFT", 0, -4)
  f.text:SetWidth(BODY_W)
  f.text:SetJustifyH("LEFT")
  SetTextColor(f.text, C.muted)
  return f
end
local function DrawNote(f, r)
  f.text:SetText(r.text)
  return math.max(18, (f.text:GetStringHeight() or 12) + 8)
end

---------------------------------------------------------------------------
-- Action cards: { kind = "cards", cards = { { label, value, color, onClick }, ... } }
-- Two per line, up to four. Clicking a card runs onClick.
---------------------------------------------------------------------------
local CARD_H = 54
function MAKE.cards()
  local f = CreateFrame("Frame", nil, content)
  f.cards = {}
  for i = 1, 4 do
    local c = CreateFrame("Button", nil, f)
    c.bg = T.Fill(c, "BACKGROUND", C.panel); c.bg:SetAllPoints()
    c.accent = T.Fill(c, "ARTWORK", C.gold)
    c.accent:SetPoint("TOPLEFT"); c.accent:SetPoint("BOTTOMLEFT"); c.accent:SetWidth(3)
    c.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.label:SetPoint("TOPLEFT", 12, -9)
    c.value = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    c.value:SetPoint("BOTTOMLEFT", 12, 9)
    c.value:SetPoint("RIGHT", -8, 0)
    c.value:SetJustifyH("LEFT")
    if c.value.SetWordWrap then c.value:SetWordWrap(false) end
    c.arrow = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.arrow:SetPoint("TOPRIGHT", -8, -9)
    c.arrow:SetText(">")
    c:SetScript("OnEnter", function(self) T.SetColor(self.bg, C.line, 1) end)
    c:SetScript("OnLeave", function(self) T.SetColor(self.bg, C.panel, 1) end)
    c:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    f.cards[i] = c
  end
  return f
end
local function DrawCards(f, r)
  local gap = 8
  local w = (BODY_W - gap) / 2
  for i, c in ipairs(f.cards) do
    local spec = r.cards[i]
    c:SetShown(spec ~= nil)
    if spec then
      local col, line = (i - 1) % 2, math.floor((i - 1) / 2)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", col * (w + gap), -line * (CARD_H + gap))
      c:SetSize(w, CARD_H)
      T.SetColor(c.accent, spec.color or C.gold, 1)
      c.label:SetText(spec.label)
      SetTextColor(c.label, spec.color or C.muted)
      c.value:SetText(spec.value)
      c.onClick = spec.onClick
      c.arrow:SetShown(spec.onClick ~= nil)
    end
  end
  return math.ceil(#r.cards / 2) * (CARD_H + gap) + 4
end

function MAKE.space() return CreateFrame("Frame", nil, content) end

---------------------------------------------------------------------------
-- Line chart: { kind = "chart", values = {...} (false = gap), labels = {...},
--               format = function(v) -> text, color = C.gold, height = 150,
--               empty = "text when there are fewer than 2 points" }
---------------------------------------------------------------------------
local CHART_PAD_L, CHART_PAD_B, CHART_PAD_T = 8, 18, 8

function MAKE.chart()
  local f = CreateFrame("Frame", nil, content)
  f.bg = T.Fill(f, "BACKGROUND", C.panel); f.bg:SetAllPoints()
  f.grid = {}
  for i = 1, 3 do
    local g = T.Fill(f, "BORDER", C.line)
    g:SetHeight(1)
    f.grid[i] = g
  end
  f.hi = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.lo = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.empty:SetPoint("CENTER")
  f.xl = {}
  for i = 1, 3 do
    local x = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.xl[i] = x
  end
  f.segments, f.dots = {}, {}
  return f
end

local function Segment(f, i)
  local s = f.segments[i]
  if s then return s end
  if f.CreateLine then
    s = f:CreateLine(nil, "ARTWORK")
    s:SetThickness(2)
  else
    s = false  -- client without lines: dots only
  end
  f.segments[i] = s
  return s
end

local function Dot(f, i)
  local d = f.dots[i]
  if d then return d end
  d = T.Fill(f, "OVERLAY", C.gold)
  d:SetSize(4, 4)
  f.dots[i] = d
  return d
end

local function DrawChart(f, r, h)
  for _, s in pairs(f.segments) do if s then s:Hide() end end
  for _, d in pairs(f.dots) do d:Hide() end
  local values, n = r.values or {}, #(r.values or {})
  local lo, hi, count = nil, nil, 0
  for i = 1, n do
    local v = values[i]
    if v then
      count = count + 1
      lo = lo and math.min(lo, v) or v
      hi = hi and math.max(hi, v) or v
    end
  end
  local w = BODY_W - CHART_PAD_L * 2
  local plotH = h - CHART_PAD_B - CHART_PAD_T
  for i, g in ipairs(f.grid) do
    g:ClearAllPoints()
    g:SetPoint("BOTTOMLEFT", CHART_PAD_L, CHART_PAD_B + (i - 1) / 2 * plotH)
    g:SetPoint("BOTTOMRIGHT", -CHART_PAD_L, CHART_PAD_B + (i - 1) / 2 * plotH)
  end
  f.empty:SetShown(count < 2)
  f.empty:SetText(r.empty or "Not enough history yet")
  f.hi:SetShown(count >= 2); f.lo:SetShown(count >= 2)
  for _, x in ipairs(f.xl) do x:Hide() end
  if count < 2 then return end

  -- A little headroom so a flat line isn't glued to the edges
  if hi == lo then hi, lo = hi * 1.05 + 1, lo * 0.95 end
  local pad = (hi - lo) * 0.08
  hi, lo = hi + pad, lo - pad
  local fmt = r.format or ns.Money
  f.hi:ClearAllPoints(); f.hi:SetPoint("TOPLEFT", CHART_PAD_L + 2, -2); f.hi:SetText(fmt(hi - pad))
  f.lo:ClearAllPoints(); f.lo:SetPoint("BOTTOMLEFT", CHART_PAD_L + 2, CHART_PAD_B + 2); f.lo:SetText(fmt(lo + pad))

  local color = r.color or C.gold
  local function XY(i, v)
    local x = CHART_PAD_L + (n == 1 and w / 2 or (i - 1) / (n - 1) * w)
    local y = CHART_PAD_B + (v - lo) / (hi - lo) * plotH
    return x, y
  end
  local prevX, prevY, seg, dots = nil, nil, 0, 0
  for i = 1, n do
    local v = values[i]
    if v then
      local x, y = XY(i, v)
      dots = dots + 1
      local d = Dot(f, dots)
      T.SetColor(d, color)
      d:SetSize(i == n and 7 or 4, i == n and 7 or 4)
      d:ClearAllPoints()
      d:SetPoint("CENTER", f, "BOTTOMLEFT", x, y)
      d:Show()
      if prevX then
        seg = seg + 1
        local s = Segment(f, seg)
        if s then
          s:SetColorTexture(color[1], color[2], color[3], 0.9)
          s:SetStartPoint("BOTTOMLEFT", f, prevX, prevY)
          s:SetEndPoint("BOTTOMLEFT", f, x, y)
          s:Show()
        end
      end
      prevX, prevY = x, y
    else
      prevX, prevY = nil, nil  -- gap: no line across missing days
    end
  end

  -- x labels: first, middle, last
  local labels = r.labels or {}
  local picks = { 1, math.floor((n + 1) / 2), n }
  for k, i in ipairs(picks) do
    if labels[i] and (k == 1 or picks[k] ~= picks[k - 1]) then
      local x = f.xl[k]
      x:ClearAllPoints()
      local px = XY(i, lo)
      x:SetPoint(k == 1 and "BOTTOMLEFT" or (k == 3 and "BOTTOMRIGHT" or "BOTTOM"), f, "BOTTOMLEFT",
        k == 3 and (px + 4) or px, 3)
      x:SetText(labels[i])
      x:Show()
    end
  end
end

---------------------------------------------------------------------------
-- Bars around a zero line: { kind = "bars", bars = { { label, value (fraction),
--   text, color }, ... }, height = 120 }
---------------------------------------------------------------------------
function MAKE.bars()
  local f = CreateFrame("Frame", nil, content)
  f.bg = T.Fill(f, "BACKGROUND", C.panel); f.bg:SetAllPoints()
  f.zero = T.Fill(f, "BORDER", C.line)
  f.zero:SetHeight(1)
  f.cols = {}
  return f
end

local function DrawBars(f, r, h)
  local bars = r.bars or {}
  local n = #bars
  local maxAbs = 0.0001
  for _, b in ipairs(bars) do if b.value then maxAbs = math.max(maxAbs, math.abs(b.value)) end end
  local top, bottom = 18, 18          -- room for value text above and label below
  local half = (h - top - bottom) / 2
  local zeroY = bottom + half
  f.zero:ClearAllPoints()
  f.zero:SetPoint("BOTTOMLEFT", 8, zeroY)
  f.zero:SetPoint("BOTTOMRIGHT", -8, zeroY)
  local slot = (BODY_W - 16) / math.max(1, n)
  for i = 1, math.max(n, #f.cols) do
    local c = f.cols[i]
    if i <= n and not c then
      c = {}
      c.bar = T.Fill(f, "ARTWORK", C.gold)
      c.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      c.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      f.cols[i] = c
    end
    if c then
      local b = bars[i]
      local shown = b ~= nil
      c.bar:SetShown(shown and b.value ~= nil and b.value ~= false)
      c.label:SetShown(shown); c.text:SetShown(shown)
      if shown then
        local cx = 8 + (i - 0.5) * slot
        c.label:ClearAllPoints(); c.label:SetPoint("BOTTOM", f, "BOTTOMLEFT", cx, 3); c.label:SetText(b.label)
        if b.value then
          local hgt = math.max(2, math.abs(b.value) / maxAbs * (half - 4))
          T.SetColor(c.bar, b.color or C.gold, 0.85)
          c.bar:ClearAllPoints()
          c.bar:SetSize(slot * 0.55, hgt)
          if b.value >= 0 then
            c.bar:SetPoint("BOTTOM", f, "BOTTOMLEFT", cx, zeroY)
            c.text:ClearAllPoints(); c.text:SetPoint("BOTTOM", f, "BOTTOMLEFT", cx, zeroY + hgt + 2)
          else
            c.bar:SetPoint("TOP", f, "BOTTOMLEFT", cx, zeroY)
            c.text:ClearAllPoints(); c.text:SetPoint("TOP", f, "BOTTOMLEFT", cx, zeroY - hgt - 2)
          end
          c.text:SetText(b.text or "")
        else
          c.text:ClearAllPoints(); c.text:SetPoint("BOTTOM", f, "BOTTOMLEFT", cx, zeroY + 2)
          c.text:SetText("-")
        end
      end
    end
  end
end

local function Draw(rows)
  ReleaseAll()
  local y, stripe = 0, 0
  for _, r in ipairs(rows) do
    local f = Acquire(r.kind, MAKE[r.kind])
    local h = HEIGHTS[r.kind]
    if r.kind == "title" then DrawTitle(f, r)
    elseif r.kind == "tiles" then DrawTiles(f, r)
    elseif r.kind == "section" then DrawSection(f, r); stripe = 0
    elseif r.kind == "row" then stripe = stripe + 1; DrawRow(f, r, stripe)
    elseif r.kind == "note" then h = DrawNote(f, r)
    elseif r.kind == "cards" then h = DrawCards(f, r)
    elseif r.kind == "chart" then h = r.height or 150; DrawChart(f, r, h)
    elseif r.kind == "bars" then h = r.height or 120; DrawBars(f, r, h)
    elseif r.kind == "space" then h = r.h or 10 end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    f:SetSize(BODY_W, h)
    y = y + h
  end
  content:SetHeight(math.max(y, 10))
end

---------------------------------------------------------------------------
-- Navigation: one row of main tabs, then (optionally) one row of subtabs with
-- a small dropdown at its right end (the period, a chart range or a filter).
---------------------------------------------------------------------------
local function Row(entries, kind, height, width, onClick)
  local gap, n = kind == "tab" and 0 or 4, #entries
  local w = (width - gap * (n - 1)) / n
  local buttons = {}
  for i, e in ipairs(entries) do
    local b = T.Button(win, e.label, kind, function() onClick(e.key) end)
    b:SetSize(w, height)
    b.x = PAD + (i - 1) * (w + gap)
    buttons[e.key] = b
  end
  return buttons
end

local function Place(buttons, y, shown)
  for _, b in pairs(buttons) do
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", b.x, y)
    b:SetShown(shown)
  end
end

local TABS_Y = -50
local tabsLine = T.Fill(win, "BORDER", C.line)
tabsLine:SetHeight(1)
tabsLine:SetPoint("TOPLEFT", PAD, TABS_Y - 30)
tabsLine:SetPoint("TOPRIGHT", -PAD, TABS_Y - 30)

-- The dropdown: a chip showing the current choice; clicking opens a list.
local DD_W = 104
local dropdown = T.Button(win, "", "chip", nil)
dropdown:SetSize(DD_W, 20)
local menu = CreateFrame("Frame", nil, win)
menu:SetFrameStrata("FULLSCREEN_DIALOG")
menu:SetWidth(DD_W)
T.Fill(menu, "BACKGROUND", C.header, 1):SetAllPoints()
local menuBorder = T.Fill(menu, "BORDER", C.border)
menuBorder:SetPoint("TOPLEFT", -1, 1); menuBorder:SetPoint("BOTTOMRIGHT", 1, -1)
menu:Hide()
local menuButtons = {}
local currentChoices  -- { list = {...}, get = fn, set = fn }

-- What the dropdown offers on the current tab/subtab, or nil.
local function ChoicesFor(tab, sub)
  if tab.choices then
    local list, id = tab.choices(sub)
    if list then
      selectedChoice[tab.key] = selectedChoice[tab.key] or {}
      local store = selectedChoice[tab.key]
      if not store[id] then store[id] = list[1].key end
      return { list = list, get = function() return store[id] end, set = function(k) store[id] = k end }
    end
  end
  if tab.periods then
    return { list = ns.PERIODS, get = function() return ns.ui.period end, set = function(k) ns.ui.period = k end }
  end
end

local function LabelOf(list, key)
  for _, e in ipairs(list) do if e.key == key then return e.label end end
  return list[1].label
end

dropdown:SetScript("OnClick", function()
  if menu:IsShown() or not currentChoices then menu:Hide(); return end
  local list = currentChoices.list
  for i, e in ipairs(list) do
    local b = menuButtons[i]
    if not b then
      b = T.Button(menu, "", "chip", nil)
      b:SetSize(DD_W - 4, 20)
      b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 22)
      menuButtons[i] = b
    end
    b.text:SetText(e.label)
    b:SetSelected(e.key == currentChoices.get())
    b:SetScript("OnClick", function()
      currentChoices.set(e.key)
      menu:Hide()
      scroll:SetVerticalScroll(0)
      ns.Refresh()
    end)
    b:Show()
  end
  for i = #list + 1, #menuButtons do menuButtons[i]:Hide() end
  menu:SetHeight(#list * 22 + 2)
  menu:ClearAllPoints()
  menu:SetPoint("TOPRIGHT", dropdown, "BOTTOMRIGHT", 0, -2)
  menu:Show()
end)
win:HookScript("OnHide", function() menu:Hide() end)

local function Build()
  table.sort(tabs, function(a, b) return (a.order or 99) < (b.order or 99) end)
  mainButtons = Row(tabs, "tab", 30, BODY_W, function(key)
    mainTab = key
    menu:Hide()
    scroll:SetVerticalScroll(0)
    ns.Refresh()
  end)
  Place(mainButtons, TABS_Y, true)
  for _, tab in ipairs(tabs) do
    if tab.subtabs then
      local hasDropdown = tab.periods or tab.choices
      subButtons[tab.key] = Row(tab.subtabs, "chip", 20, hasDropdown and (BODY_W - DD_W - 8) or BODY_W, function(key)
        selectedSub[tab.key] = key
        menu:Hide()
        scroll:SetVerticalScroll(0)
        ns.Refresh()
      end)
    end
  end
end

ns.OnInit(function()
  Build()
  ns.MakeMovable(win, "winPos")
  ns.RestorePosition(win, "winPos", "CENTER")
end)

-- Header subtitle: who you are, and how old the AH prices are.
local function Subtitle()
  if not ns.db then return end
  local text = ns.db.name .. (ns.db.realmLabel and ("  ·  " .. ns.db.realmLabel) or "")
  local s = ns.Prices.Status()
  if s.source == "blizzard" and s.updated then
    local mins = math.max(0, math.floor((time() - s.updated) / 60))
    local age = mins < 90 and (mins .. " min") or (mins < 2880 and (math.floor(mins / 60) .. " h") or (math.floor(mins / 1440) .. " days"))
    local color = mins > 360 and "|cffff6b6b" or (mins > 120 and "|cffffd100" or "")
    text = text .. "  ·  " .. color .. "prices " .. age .. " old" .. (color ~= "" and "|r" or "")
  elseif s.source == "none" then
    text = text .. "  ·  |cffff6b6bno AH prices|r"
  end
  subtitle:SetText(text)
end
win:HookScript("OnShow", Subtitle)

ns.OnRefresh(function()
  if not win:IsShown() or not mainTab then return end
  Subtitle()
  local tab = tabByKey[mainTab]
  for key, b in pairs(mainButtons) do b:SetSelected(key == mainTab) end

  local y = TABS_Y - 40
  for key, subs in pairs(subButtons) do
    Place(subs, y, key == mainTab)
    for subKey, b in pairs(subs) do b:SetSelected(subKey == selectedSub[key]) end
  end
  currentChoices = ChoicesFor(tab, selectedSub[mainTab])
  dropdown:SetShown(currentChoices ~= nil)
  if currentChoices then
    dropdown.text:SetText(LabelOf(currentChoices.list, currentChoices.get()) .. "  |cff999999v|r")
    dropdown:ClearAllPoints()
    dropdown:SetPoint("TOPRIGHT", -PAD, y)
  else
    menu:Hide()
  end
  if tab.subtabs or currentChoices then y = y - 28 end
  footer:SetShown(tab.periods == true and ns.ui.period == "session")

  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", PAD, y - 6)
  scroll:SetPoint("BOTTOMRIGHT", -PAD, 28)
  Draw(tab.render(selectedSub[mainTab], ns.ui.period, currentChoices and currentChoices.get()))
end)

win:SetScript("OnShow", function() ns.Refresh() end)

-- Open a tab (and optionally a subtab). With no arguments, toggle the window.
function ns.OpenTab(tabKey, subKey)
  if not tabKey and win:IsShown() then win:Hide(); return end
  if tabKey and tabByKey[tabKey] then mainTab = tabKey end
  if subKey then selectedSub[mainTab] = subKey end
  win:Show()
  ns.Refresh()
end
