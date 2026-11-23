-- Cutpurse Ledger: the small draggable box. Everything in it is for TODAY:
-- today's profit, then what each activity brought in today.

local ADDON, ns = ...
local G = ns.Gathering
local T = ns.Theme
local C = T.C

local WIDTH = 190
local ROW_H = 18

local box = CreateFrame("Frame", "LootLedgerBox", UIParent)
ns.box = box
box:SetSize(WIDTH, 60)
box:Hide()
T.Panel(box, { 0.05, 0.05, 0.07, 0.88 })

local icon = T.Icon(box, 16)
icon:SetPoint("TOPLEFT", 8, -7)
icon:SetTexture(T.GOLD_ICON)
local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
title:SetText("TODAY")
local profit = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
profit:SetPoint("RIGHT", box, "TOPRIGHT", -8, -15)

local divider = T.Fill(box, "BORDER", C.line)
divider:SetHeight(1)
divider:SetPoint("TOPLEFT", 6, -28)
divider:SetPoint("TOPRIGHT", -6, -28)

local lines = {}
local function Line(i)
  local l = lines[i]
  if l then return l end
  l = CreateFrame("Frame", nil, box)
  l:SetSize(WIDTH - 16, ROW_H)
  l:SetPoint("TOPLEFT", 8, -32 - (i - 1) * ROW_H)
  l.icon = T.Icon(l, 14)
  l.icon:SetPoint("LEFT")
  l.label = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  l.label:SetPoint("LEFT", l.icon, "RIGHT", 6, 0)
  l.label:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
  l.value = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  l.value:SetPoint("RIGHT")
  lines[i] = l
  return l
end

local hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetText("Nothing gathered yet today")

box:SetScript("OnMouseUp", function(self, button)
  if self.dragging then self.dragging = false; return end
  if button == "LeftButton" then ns.OpenTab() end
end)
box:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Cutpurse Ledger: today")
  GameTooltip:AddLine("Top right: today's profit (earned minus spent).", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Below: what each activity brought in today.", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Click to open. Drag to move.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end)
box:SetScript("OnLeave", function() GameTooltip:Hide() end)

ns.OnInit(function()
  ns.MakeMovable(box, "boxPos")
  ns.RestorePosition(box, "boxPos", "CENTER", UIParent, "CENTER", 0, 200)
  box:SetShown(ns.ui.boxShown)
end)

ns.OnRefresh(function()
  local inc, exp = ns.Ledger.Sum("today")
  profit:SetText(ns.Signed(inc - exp))

  local n = 0
  for _, a in ipairs(G.ACTIVITIES) do
    local t = G.Sum(a.key, "today")
    if t.count + t.empty > 0 then
      n = n + 1
      local l = Line(n)
      l.icon:SetTexture(T.ActivityIcon(a))
      l.label:SetText(a.label)
      l.value:SetText(ns.Money(G.Value(t)))
      l:Show()
    end
  end
  for i = n + 1, #lines do lines[i]:Hide() end

  hint:SetShown(n == 0)
  hint:ClearAllPoints()
  hint:SetPoint("TOPLEFT", 10, -34)
  box:SetHeight(n == 0 and 52 or (36 + n * ROW_H))
end)

function ns.ToggleBox()
  ns.ui.boxShown = not box:IsShown()
  box:SetShown(ns.ui.boxShown)
end
