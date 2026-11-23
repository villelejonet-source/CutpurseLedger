-- Cutpurse Ledger: which items are needed for quests.
--
-- Uses QuestieDB's public in-game API (the QuestDB global) when the player has
-- Questie installed. Nothing from Questie is copied or shipped with Cutpurse
-- Ledger; without Questie this module simply stays off.
--
-- QuestieDB stores, per quest, the items it asks for (objectives group 3) and
-- items needed but not counted as objectives (requiredSourceItems). It doesn't
-- store how many, so we show the quest, not a count.

local ADDON, ns = ...
local Q = {}
ns.Quests = Q

local PER_FRAME = 250   -- quests indexed per frame, so the game never stutters
local index             -- itemID -> { { id, name, level }, ... } sorted by level, highest first
local state = "off"     -- "off" | "building" | "ready"

local function DB()
  local db = _G.QuestDB
  if type(db) == "table" and type(db.GetAllIds) == "function" and type(db.Get) == "function" then return db end
end

function Q.Available() return DB() ~= nil end
function Q.State() return state end

local function Add(map, itemID, quest)
  if type(itemID) ~= "number" then return end
  local list = map[itemID]
  if not list then list = {}; map[itemID] = list end
  for _, q in ipairs(list) do if q.id == quest.id then return end end
  list[#list + 1] = quest
end

function Q.Build()
  local db = DB()
  if not db or state ~= "off" then return end
  state = "building"
  local ok, ids = pcall(db.GetAllIds)
  if not ok or type(ids) ~= "table" then state = "off"; return end
  local map, i = {}, 1
  local function Step()
    local stop = math.min(#ids, i + PER_FRAME - 1)
    for n = i, stop do
      local id = ids[n]
      local okO, objectives = pcall(db.Get, id, "objectives")
      local okR, required = pcall(db.Get, id, "requiredSourceItems")
      local itemObjectives = okO and type(objectives) == "table" and objectives[3]
      local hasItems = (type(itemObjectives) == "table" and #itemObjectives > 0) or (okR and type(required) == "table" and #required > 0)
      if hasItems then
        local quest = { id = id, name = db.Get(id, "name") or ("quest " .. id), level = db.Get(id, "questLevel") or db.Get(id, "requiredLevel") or 0 }
        if type(itemObjectives) == "table" then
          for _, o in ipairs(itemObjectives) do Add(map, type(o) == "table" and o[1] or o, quest) end
        end
        if okR and type(required) == "table" then
          for _, itemID in ipairs(required) do Add(map, itemID, quest) end
        end
      end
    end
    i = stop + 1
    if i <= #ids then
      C_Timer.After(0, Step)
    else
      for _, list in pairs(map) do table.sort(list, function(a, b) return a.level > b.level end) end
      index, state = map, "ready"
      ns.Refresh()
    end
  end
  Step()
end

-- Quests that need this item, highest level first (nil if none or not ready).
function Q.For(itemID)
  return index and index[itemID] or nil
end

-- Highest quest level that needs this item, or nil.
function Q.Level(itemID)
  local list = Q.For(itemID)
  return list and list[1].level or nil
end

-- Start once the game has settled, so login stays fast.
ns.On("PLAYER_ENTERING_WORLD", function()
  if state == "off" and Q.Available() then C_Timer.After(8, Q.Build) end
end)
