-- Cutpurse Ledger: look and feel. Colors, icons and small widget factories shared
-- by the window and the box. Everything is drawn with flat color textures so
-- it looks the same on every client.

local ADDON, ns = ...
local T = {}
ns.Theme = T

T.C = {
  bg       = { 0.055, 0.055, 0.07, 0.97 },
  header   = { 0.09, 0.08, 0.06, 1 },
  panel    = { 0.12, 0.12, 0.15, 1 },
  panelHi  = { 0.18, 0.18, 0.22, 1 },
  stripe   = { 1, 1, 1, 0.035 },
  border   = { 0.45, 0.36, 0.14, 1 },
  line     = { 1, 1, 1, 0.08 },
  gold     = { 1, 0.80, 0.25, 1 },
  text     = { 0.93, 0.93, 0.93, 1 },
  muted    = { 0.58, 0.58, 0.64, 1 },
  dark     = { 0.08, 0.07, 0.05, 1 },
  green    = { 0.36, 0.86, 0.46, 1 },
  red      = { 1, 0.42, 0.42, 1 },
  blue     = { 0.45, 0.70, 1, 1 },
}
local C = T.C

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------
function T.Hex(c)
  return string.format("ff%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end
function T.Color(text, c) return "|c" .. T.Hex(c) .. text .. "|r" end

local QUALITY_HEX = { [0] = "ff9d9d9d", "ffffffff", "ff1eff00", "ff0070dd", "ffa335ee", "ffff8000", "ffe6cc80" }
function T.QualityText(text, quality)
  return "|c" .. (QUALITY_HEX[quality or 1] or "ffffffff") .. text .. "|r"
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------
local I = "Interface\\Icons\\"
T.SOURCE_ICONS = {
  loot = I .. "INV_Misc_Bag_08",        quest = I .. "INV_Misc_Note_01",
  vendor_sell = I .. "INV_Misc_Coin_02", vendor_buy = I .. "INV_Misc_Coin_04",
  repair = I .. "Trade_BlackSmithing",
  ah_sale = I .. "INV_Misc_Coin_01",     ah_refund = I .. "INV_Misc_Coin_03",
  ah_deposit = I .. "INV_Misc_Coin_05",  ah_buy = I .. "INV_Misc_Coin_06",
  mail_in = I .. "INV_Letter_15",        mail_out = I .. "INV_Letter_15",
  trade = I .. "INV_Misc_Gift_01",       training = I .. "INV_Misc_Book_09",
  flight = I .. "INV_Misc_Map_01",       bank = I .. "INV_Box_01",
  other = I .. "INV_Misc_QuestionMark",
}
local ACTIVITY_FALLBACK = {
  pickpocket = I .. "INV_Misc_Bag_11", skinning = I .. "INV_Misc_Pelt_Wolf_01",
  mining = I .. "Trade_Mining", herbalism = I .. "Trade_Herbalism",
}
T.GOLD_ICON = I .. "INV_Misc_Coin_01"
T.BAG_ICON = I .. "INV_Misc_Bag_10"

function T.ActivityIcon(a)
  local tex
  if C_Spell and C_Spell.GetSpellTexture then tex = C_Spell.GetSpellTexture(a.spell)
  elseif GetSpellTexture then tex = GetSpellTexture(a.spell) end
  return tex or ACTIVITY_FALLBACK[a.key]
end

function T.SourceIcon(source)
  local a = ns.Gathering.BY_KEY[source]
  if a then return T.ActivityIcon(a) end
  return T.SOURCE_ICONS[source] or T.SOURCE_ICONS.other
end

function T.ItemIcon(id)
  if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
  if GetItemIcon then return GetItemIcon(id) end
  return select(10, ns.ItemInfo(id)) or T.SOURCE_ICONS.other
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
function T.Fill(frame, layer, c, sublevel)
  local t = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
  T.SetColor(t, c)
  return t
end

function T.SetColor(tex, c, alpha)
  if tex.SetColorTexture then
    tex:SetColorTexture(c[1], c[2], c[3], alpha or c[4] or 1)
  else
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    tex:SetVertexColor(c[1], c[2], c[3], alpha or c[4] or 1)
  end
end

-- 1px border around a frame.
function T.Border(frame, c)
  local edges = {}
  for i, spec in ipairs({
    { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
    { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
  }) do
    local e = T.Fill(frame, "BORDER", c)
    e:SetPoint(spec[1]); e:SetPoint(spec[2])
    if spec[3] then e:SetWidth(spec[3]) end
    if spec[4] then e:SetHeight(spec[4]) end
    edges[i] = e
  end
  return edges
end

-- Dark panel with a thin gold border.
function T.Panel(frame, bg, border)
  local b = T.Fill(frame, "BACKGROUND", bg or C.bg)
  b:SetAllPoints()
  T.Border(frame, border or C.border)
  return b
end

function T.Icon(parent, size)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(size, size)
  t:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- trim the default icon border
  return t
end

---------------------------------------------------------------------------
-- Buttons: "tab" (underlined text), "pill" (segmented control), "chip" (small filter)
---------------------------------------------------------------------------
local function Style(b)
  local hover, sel = b.hover, b.selected
  if b.kind == "tab" then
    b.line:SetShown(sel)
    local c = sel and C.gold or (hover and C.text or C.muted)
    b.text:SetTextColor(c[1], c[2], c[3])
  elseif b.kind == "pill" then
    T.SetColor(b.bg, sel and C.gold or (hover and C.panelHi or C.panel))
    local c = sel and C.dark or (hover and C.text or C.muted)
    b.text:SetTextColor(c[1], c[2], c[3])
  else -- chip
    T.SetColor(b.bg, sel and { 0.30, 0.24, 0.08, 1 } or (hover and C.panelHi or C.panel))
    local c = sel and C.gold or (hover and C.text or C.muted)
    b.text:SetTextColor(c[1], c[2], c[3])
  end
end

function T.Button(parent, label, kind, onClick)
  local b = CreateFrame("Button", nil, parent)
  b.kind = kind
  b.bg = T.Fill(b, "BACKGROUND", C.panel)
  b.bg:SetAllPoints()
  b.text = b:CreateFontString(nil, "OVERLAY", kind == "tab" and "GameFontNormal" or "GameFontHighlightSmall")
  b.text:SetPoint("CENTER", 0, kind == "tab" and 1 or 0)
  b.text:SetText(label)
  if kind == "tab" then
    b.bg:SetAlpha(0)
    b.line = T.Fill(b, "ARTWORK", C.gold)
    b.line:SetHeight(2)
    b.line:SetPoint("BOTTOMLEFT", 6, 0)
    b.line:SetPoint("BOTTOMRIGHT", -6, 0)
  end
  b:SetScript("OnEnter", function(self) self.hover = true; Style(self) end)
  b:SetScript("OnLeave", function(self) self.hover = false; Style(self) end)
  b:SetScript("OnClick", onClick)
  function b:SetSelected(v) self.selected = v; Style(self) end
  Style(b)
  return b
end
