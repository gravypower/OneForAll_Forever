local _, FLT = ...
local L = FLT.L or setmetatable({}, { __index = function(_, k) return k end }) -- (tests without Locales)

-- Bag advice icons: a small icon in the bottom left corner of an item in the bags that says what the Bag advice
-- (UI/BagAdvice.lua) would do with it, so the bags can be read without pointing at every item:
--   coin = sell to a merchant, gavel = auction house (or disenchant), letter = mail to an alt, chest = put in the bank,
--   red cross = destroy. Items to keep, use or equip get no icon (upgrades have the Gear Value arrow).
-- Quality of Life > Tooltips > "Bag advice icons" (QoL key bagAdviceIcons, needs "Bag advice"), off by default.
-- The game's bags (also the Combined Backpack) and Baganator (its corner icons: the player can move it there).

local BA = FLT.BagAdvice
if not BA then return end
local BM = {}
FLT.BagMarks = BM

local function Q(key) return FLT.QoL and FLT.QoL.Get and FLT.QoL.Get(key) end
local function on() return Q("bagAdvice") and Q("bagAdviceIcons") and true or false end

local ICON = {
  vendor = "Interface\\MoneyFrame\\UI-GoldIcon",
  ah = "Interface\\Minimap\\Tracking\\Auctioneer",
  mail = "Interface\\Minimap\\Tracking\\Mailbox",
  bank = "Interface\\Minimap\\Tracking\\Banker",
  destroy = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
}
BM.ICON = ICON

-- which icon an advice gets: "vendor" / "ah" / "mail" / "bank" / "destroy" or nil
local function markOf(kind, act)
  if act then return act end
  if kind == "sell" then return "ah" end
  if kind == "drop" then return "destroy" end
  return nil
end
-- The advice per item is kept until something changes it (bags, quests, level, skills, gear, settings): bag frames
-- redraw often. Key: the link, and whether this one is soulbound (a worn Bind on Equip item has the same link).
local cache = {}
local function forget() for k in pairs(cache) do cache[k] = nil end end
local function markFor(id, link, bound, flags)
  if not (id and link) then return nil end
  local key = link .. (bound and "#" or "")
  local m = cache[key]
  if m == nil then
    local text, kind, act = BA.Advice(id, link, flags())
    if not text and not (GetItemInfo and GetItemInfo(link)) then return nil end -- no item data yet: asked again later
    m = markOf(kind, act) or false
    cache[key] = m
  end
  return m or nil
end
function BM.SlotMark(bag, slot)
  local i = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
  if type(i) ~= "table" or not i.itemID then return nil end
  return markFor(i.itemID, i.hyperlink, i.isBound, function() return BA.SlotFlags(bag, slot, i) end)
end

-- The game's bags ----------------------------------------------------------------------------
local function buttonsOf(frame)
  if frame.EnumerateValidItems then
    local list = {}
    for _, b in frame:EnumerateValidItems() do list[#list + 1] = b end
    return list
  end
  if frame.Items then return frame.Items end
  local list, name = {}, frame.GetName and frame:GetName()
  for i = 1, (frame.size or 36) do local b = name and _G[name .. "Item" .. i]; if b then list[#list + 1] = b end end
  return list
end
local function paint(b, m)
  local t = b.ofaAdvice
  if not m then if t then t:Hide() end return end
  if not t then
    t = b:CreateTexture(nil, "OVERLAY", nil, 6); t:SetSize(14, 14); t:SetPoint("BOTTOMLEFT", 1, 1)
    b.ofaAdvice = t
  end
  if t.ofaMark ~= m then t.ofaMark = m; t:SetTexture(ICON[m]) end
  t:Show()
end
local function markBag(frame)
  if type(frame) ~= "table" or not (frame.IsShown and frame:IsShown()) then return end
  local active = on()
  for _, b in ipairs(buttonsOf(frame)) do
    local m
    if active and b:IsShown() then
      local bag = b.GetBagID and b:GetBagID() or frame:GetID()
      m = BM.SlotMark(bag, b:GetID())
    end
    if m or b.ofaAdvice then paint(b, m) end
  end
end
local function bagFrames()
  local list = {}
  for i = 1, (tonumber(NUM_CONTAINER_FRAMES) or 13) do local f = _G["ContainerFrame" .. i]; if f then list[#list + 1] = f end end
  if ContainerFrameCombinedBags then list[#list + 1] = ContainerFrameCombinedBags end
  return list
end
local function safe(fn, ...) if FLT.SafeCall then FLT.SafeCall("BagMarks", fn, ...) else pcall(fn, ...) end end
local function markSafe(frame) safe(markBag, frame) end

-- Baganator: a corner icon of its own (no bag slot there: the tooltip-only rules - old food, potions, bag sizes -
-- are not seen, the rest is)
local baganator
local NONE = {}
local function hookBaganator()
  local api = Baganator and Baganator.API
  if baganator or not (api and api.RegisterCornerWidget) then return end
  baganator = api
  pcall(api.RegisterCornerWidget, L["OneForAll: bag advice"], "oneforall_bagadvice", function(t, details)
    if not on() or type(details) ~= "table" then return false end
    local link = details.itemLink
    local id = details.itemID or (link and tonumber(link:match("item:(%d+)")))
    if not (id and link) then return false end
    if not GetItemInfo(link) then return nil end
    local m = markFor(id, link, details.isBound, function() return details.isBound and { bound = true } or NONE end)
    if m and type(t) == "table" and t.SetTexture and t.ofaMark ~= m then t.ofaMark = m; t:SetTexture(ICON[m]) end
    return m and true or false
  end, function(button)
    local t = button:CreateTexture(nil, "OVERLAY"); t:SetSize(14, 14)
    return t
  end, { corner = "bottom_left", priority = 1 })
end

-- gameOnly: not Baganator (it asks again by itself while item data is missing)
function BM.Refresh(gameOnly)
  forget()
  for _, f in ipairs(bagFrames()) do markSafe(f) end
  if not gameOnly and baganator and baganator.RequestItemButtonsRefresh then pcall(baganator.RequestItemButtonsRefresh) end
end
local pending, pendingAll
local function later(gameOnly)
  if not gameOnly then pendingAll = true end
  if pending then return end
  if not (C_Timer and C_Timer.After) then BM.Refresh(gameOnly); return end
  pending = true
  C_Timer.After(0.3, function() local all = pendingAll; pending, pendingAll = false, false; BM.Refresh(not all) end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event)
  if event == "PLAYER_LOGIN" then
    self:UnregisterEvent("PLAYER_LOGIN")
    if type(ContainerFrame_Update) == "function" and hooksecurefunc then hooksecurefunc("ContainerFrame_Update", markSafe) end
    for _, f in ipairs(bagFrames()) do
      if type(f.UpdateItems) == "function" and hooksecurefunc then hooksecurefunc(f, "UpdateItems", markSafe) end
      if f.HookScript then f:HookScript("OnShow", markSafe) end
    end
    safe(hookBaganator)
    -- what changes an advice: the bags, quests, level, professions, worn gear, item data arriving
    for _, e in ipairs({ "BAG_UPDATE_DELAYED", "QUEST_LOG_UPDATE", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED",
      "PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED" }) do pcall(self.RegisterEvent, self, e) end
    return
  end
  if not on() then return end
  later(event == "GET_ITEM_INFO_RECEIVED")
end)
if FLT.QoL and FLT.QoL.On then
  FLT.QoL.On("bagAdviceIcons", function() BM.Refresh() end)
  FLT.QoL.On("bagAdvice", function() BM.Refresh() end)
end

BM._ev, BM._markBag = ev, markBag -- tests
