local _, FLT = ...
local L = FLT.L or setmetatable({}, { __index = function(_, k) return k end }) -- (tests without Locales)
local UI = FLT.UI or {}

-- Clear my bags: one window with everything the Bag advice (UI/BagAdvice.lua) would take out of the bags, by what to
-- do with it - sell to a merchant (with the total), auction house, mail to which character, put in the bank,
-- destroy - so you see whether a trip to town is worth it. /ofa bags opens and closes it (needs "Bag advice").
-- Only a list: the buttons at the merchant, bank and mailbox (UI/BagActions.lua) do the work.

local BA = FLT.BagAdvice
if not BA then return end
local BS = {}
FLT.BagSummary = BS

local function Q(key) return FLT.QoL and FLT.QoL.Get and FLT.QoL.Get(key) end
local function money(c) return FLT.QoL and FLT.QoL.Money and FLT.QoL.Money(c) or tostring(c) end
local function msg(text) if FLT.Msg then FLT.Msg(text) end end

-- The groups in the order shown; mail has one group per character ("mail:Banky")
local ORDER = { "vendor", "ah", "mail", "bank", "destroy" }
local function title(key, to)
  if key == "vendor" then return L["Sell to a merchant"] end
  if key == "ah" then return L["Sell in the auction house (or disenchant)"] end
  if key == "mail" then return string.format(L["Mail to %s"], to or "?") end
  if key == "bank" then return L["Put in your bank"] end
  return L["Destroy"]
end

-- What the bags hold: groups = list of { key, title, slots, value (merchant), ah (auction house, when known),
-- items = { { link, n, why } } } in the order shown; used / total = bag slots; out = slots that can go
function BS.Collect()
  local groups, by, used, total, out = {}, {}, 0, 0, 0
  if not (C_Container and C_Container.GetContainerItemInfo) then return groups, used, total, out end
  local get = GetItemInfo or (C_Item and C_Item.GetItemInfo)
  local SU = FLT.SkillUp
  local hasAH = SU and SU.HasAuctionator and SU.HasAuctionator() and SU.AHPrice
  for _, bag in ipairs(BA.BagIds()) do
    local n = BA.NumSlots(bag)
    total = total + n
    for slot = 1, n do
      local i = C_Container.GetContainerItemInfo(bag, slot)
      if type(i) == "table" and i.itemID and i.hyperlink then
        used = used + 1
        local text, kind, act, to = BA.Advice(i.itemID, i.hyperlink, BA.SlotFlags(bag, slot, i))
        local key = act or (kind == "sell" and "ah") or (kind == "drop" and "destroy") or nil
        if text and key then
          out = out + 1
          local gk = key == "mail" and ("mail:" .. tostring(to)) or key
          local g = by[gk]
          if not g then
            g = { key = key, to = to, title = title(key, to), slots = 0, value = 0, ah = 0, items = {}, byLink = {} }
            by[gk] = g
          end
          local count = i.stackCount or 1
          local _, _, _, _, _, _, _, _, _, _, price = get(i.hyperlink)
          g.slots = g.slots + 1
          g.value = g.value + (price or 0) * count
          if key == "ah" and hasAH then g.ah = g.ah + (SU.AHPrice(i.itemID) or 0) * count * 0.95 end
          local e = g.byLink[i.hyperlink]
          if e then e.n = e.n + count
          else
            -- "Sell to a merchant (24c) - junk": the reason is the part after the dash
            e = { link = i.hyperlink, n = count, why = text:match(" %- (.+)$") }
            g.byLink[i.hyperlink] = e; g.items[#g.items + 1] = e
          end
        end
      end
    end
  end
  for _, key in ipairs(ORDER) do
    local names = {}
    for gk, g in pairs(by) do if g.key == key then names[#names + 1] = gk end end
    table.sort(names)
    for _, gk in ipairs(names) do by[gk].byLink = nil; groups[#groups + 1] = by[gk] end
  end
  return groups, used, total, out
end

-- The text of the window (also for tests): the head line and the body
function BS.Text()
  local groups, used, total, out = BS.Collect()
  local head = string.format(L["%d of %d bag slots used - %d can go"], used, total, out)
  if #groups == 0 then return head, L["Nothing to clear out: the advice would keep everything in your bags."] end
  local lines = {}
  for _, g in ipairs(groups) do
    local sum = ""
    if g.key == "vendor" and g.value > 0 then sum = "  " .. money(g.value)
    elseif g.key == "ah" and g.ah > 0 then sum = "  " .. string.format(L["about %s"], money(g.ah)) end
    lines[#lines + 1] = "|cffffd133" .. g.title .. "|r  |cffb0b0b0(" .. g.slots .. ")|r" .. sum
    for _, e in ipairs(g.items) do
      lines[#lines + 1] = "   " .. e.link .. (e.n > 1 and (" x" .. e.n) or "") .. (e.why and ("  |cff909090" .. e.why .. "|r") or "")
    end
    lines[#lines + 1] = " "
  end
  return head, table.concat(lines, "\n")
end

-- The window -----------------------------------------------------------------------------------
local W = 420
local frame, sf, child, body, headFS
local function fill()
  if not (frame and frame:IsShown()) then return end
  local head, text = BS.Text()
  headFS:SetText(head)
  body:SetText(text)
  child:SetHeight(math.max(10, (body.GetStringHeight and body:GetStringHeight() or 10) + 8))
end
local function create()
  frame = CreateFrame("Frame", "OneForAllBagSummary", UIParent)
  frame:SetSize(W, 380); frame:SetFrameStrata("FULLSCREEN"); frame:SetClampedToScreen(true)
  frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
  local pos = type(OneForAllDB) == "table" and OneForAllDB.bagSummaryPos
  if type(pos) == "table" then frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else frame:SetPoint("CENTER", -260, 40) end
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint(1)
    if type(OneForAllDB) == "table" then OneForAllDB.bagSummaryPos = { p, rp, x, y } end
  end)
  if UI.FramedPanel then UI.FramedPanel(frame) end
  if UI.OrnateFrame and FLT.SkinC then
    for _, t in ipairs(UI.OrnateFrame(frame, frame, 16, 3, "OVERLAY", 4)) do t:SetVertexColor(FLT.SkinC(1, 1, 1, 1)) end
  end
  if UI.CloseButton then local close = UI.CloseButton(frame); close:SetPoint("TOPRIGHT", -12, -12) end
  local newFS = FLT.NewFS or function(owner, ...) return owner:CreateFontString(...) end
  local titleFS = newFS(frame, nil, "OVERLAY", "GameFontNormal"); titleFS:SetPoint("TOPLEFT", 18, -15)
  titleFS:SetText(L["Clear my bags"])
  local gold = UI.GOLD or { 1, 0.82, 0.2 }
  titleFS:SetTextColor(gold[1], gold[2], gold[3])
  headFS = newFS(frame, nil, "OVERLAY", "GameFontHighlightSmall"); headFS:SetPoint("TOPLEFT", 18, -36)
  sf = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  if FLT.SkinBlizz then FLT.SkinBlizz(sf) end
  sf:SetPoint("TOPLEFT", 8, -56); sf:SetPoint("BOTTOMRIGHT", -30, 14)
  child = CreateFrame("Frame", nil, sf); child:SetSize(W - 38, 10); sf:SetScrollChild(child)
  if UI.PlaceScrollBar then UI.PlaceScrollBar(sf) end
  body = newFS(child, nil, "OVERLAY", "GameFontHighlightSmall")
  body:SetPoint("TOPLEFT", 10, -4); body:SetWidth(W - 60); body:SetJustifyH("LEFT")
  if body.SetSpacing then body:SetSpacing(3) end
  frame:SetScript("OnShow", fill)
  -- Escape closes it
  if type(UISpecialFrames) == "table" then UISpecialFrames[#UISpecialFrames + 1] = "OneForAllBagSummary" end
end

function BS.Toggle()
  if not Q("bagAdvice") then
    msg(L["Switch on Quality of Life > Tooltips > \"Bag advice\" first."])
    return
  end
  if not frame then create(); frame:Show(); fill(); return end
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- bag changes while it is open (in bursts: once, a moment later)
local waiting = false
local ev = CreateFrame("Frame")
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "QUEST_LOG_UPDATE" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function()
  if waiting or not (frame and frame:IsShown()) then return end
  local function go() waiting = false; if FLT.SafeCall then FLT.SafeCall("BagSummary", fill) else pcall(fill) end end
  if C_Timer and C_Timer.After then waiting = true; C_Timer.After(0.4, go) else go() end
end)
