local _, FLT = ...
local L = FLT.L or setmetatable({}, { __index = function(_, k) return k end }) -- (tests without Locales)

-- Bag advice buttons: one button that does what the Bag advice (UI/BagAdvice.lua) says, where it can be done.
--  * at a merchant: "Sell 7 items (2g 10s)" - everything the advice marks "Sell to a merchant", after a confirmation
--    that lists the items. Never blue or better items, never gear (it may be for another spec; grey gear and your
--    junk list are sold), never what the advice would rather see in the auction house.
--  * at the bank: "Put 5 items in the bank" - what the advice marks "put it in your bank".
--  * at the mailbox: "Mail 4 items to Banky" - fills the name and attaches the items; you click Send yourself.
-- Quality of Life > Tooltips > "Bag advice buttons" (QoL key bagAdviceButtons, needs "Bag advice"), off by default.
-- The button shows what it will take when the mouse is over it.

local BA = FLT.BagAdvice
if not BA then return end
local AC = {}
FLT.BagActions = AC

local function Q(key) return FLT.QoL and FLT.QoL.Get and FLT.QoL.Get(key) end
local function on() return Q("bagAdvice") and Q("bagAdviceButtons") and true or false end
local function money(c) return FLT.QoL and FLT.QoL.Money and FLT.QoL.Money(c) or tostring(c) end
local function msg(text) if FLT.Msg then FLT.Msg(text) end end
local MAX_MAIL = tonumber(ATTACHMENTS_MAX_SEND) or 12

local function slotInfo(bag, slot)
  local i = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
  return type(i) == "table" and i or nil
end

-- What to do with the bags: list of { bag, slot, link, n = stack size, value = merchant price of the stack, to,
-- toName } for one act ("vendor" / "bank" / "mail"). Mail: only the character that gets the most, at most 12.
function AC.Plan(act)
  local list = {}
  if not (C_Container and C_Container.GetContainerItemInfo) then return list end
  local get = GetItemInfo or (C_Item and C_Item.GetItemInfo)
  for _, bag in ipairs(BA.BagIds()) do
    for slot = 1, BA.NumSlots(bag) do
      local i = slotInfo(bag, slot)
      if i and i.itemID and i.hyperlink and not i.isLocked then
        local _, _, a, to, toName = BA.Advice(i.itemID, i.hyperlink, BA.SlotFlags(bag, slot, i))
        if a == act then
          local _, _, quality, _, _, _, _, _, loc, _, price = get(i.hyperlink)
          local n = i.stackCount or 1
          -- selling: never blue or better, never what no merchant buys, and no gear you could wear (it may be for
          -- another spec) unless it is grey or on your junk list
          local gear = loc and loc ~= "" and loc ~= "INVTYPE_BAG" and loc ~= "INVTYPE_AMMO" and (quality or 9) > 0
            and not (Q("sellJunk") and FLT.QoL.IsJunk and FLT.QoL.IsJunk(i.itemID))
          if act ~= "vendor" or ((quality or 9) <= 2 and (price or 0) > 0 and not i.hasNoValue and not gear) then
            list[#list + 1] = { bag = bag, slot = slot, link = i.hyperlink, n = n, value = (price or 0) * n, to = to, toName = toName }
          end
        end
      end
    end
  end
  if act == "mail" then
    local per, best = {}, nil
    for _, e in ipairs(list) do
      per[e.toName] = (per[e.toName] or 0) + 1
      if not best or per[e.toName] > per[best] or (per[e.toName] == per[best] and e.toName < best) then best = e.toName end
    end
    local out = {}
    for _, e in ipairs(list) do if e.toName == best and #out < MAX_MAIL then out[#out + 1] = e end end
    return out
  end
  return list
end

-- Doing it: one slot every 0.15 s, each checked again right before (the same item, not locked, the window still open)
local ticker
local function run(list, open, done)
  if ticker then ticker:Cancel(); ticker = nil end
  if #list == 0 or not (C_Timer and C_Timer.NewTicker) then return end
  local use = C_Container and C_Container.UseContainerItem
  if not use then return end
  local i, n, value = 0, 0, 0
  local function stop()
    if ticker then ticker:Cancel(); ticker = nil end
    if n > 0 then done(n, value) end
  end
  ticker = C_Timer.NewTicker(0.15, function()
    i = i + 1
    if not open() or not on() then stop(); return end
    local e = list[i]
    local now = e and slotInfo(e.bag, e.slot)
    if now and now.hyperlink == e.link and not now.isLocked then
      pcall(use, e.bag, e.slot)
      n = n + 1; value = value + e.value
    end
    if i >= #list then stop() end
  end, #list)
end

local function shown(f) return type(f) == "table" and f.IsShown and f:IsShown() and true or false end
local place -- "merchant" / "bank" / "mail" / nil: what is open
local PLACES = {
  merchant = { act = "vendor", frame = function() return MerchantFrame end,
    label = function(list)
      local total = 0
      for _, e in ipairs(list) do total = total + e.value end
      return string.format(#list == 1 and L["Sell 1 item (%s)"] or L["Sell %d items (%s)"], #list == 1 and money(total) or #list, money(total))
    end },
  bank = { act = "bank", frame = function() return BankFrame end,
    label = function(list) return #list == 1 and L["Put 1 item in the bank"] or string.format(L["Put %d items in the bank"], #list) end },
  mail = { act = "mail", frame = function() return MailFrame end,
    label = function(list) return string.format(#list == 1 and L["Mail 1 item to %s"] or L["Mail %d items to %s"], #list == 1 and list[1].to or #list, list[1].to) end },
}

local function sellNow(list)
  run(list, function() return place == "merchant" end, function(n, value)
    msg(n == 1 and string.format(L["Sold 1 item for %s."], money(value)) or string.format(L["Sold %d items for %s."], n, money(value)))
  end)
end
local function click()
  local p = PLACES[place]
  if not (p and on()) then return end
  local list = AC.Plan(p.act)
  if #list == 0 then return end
  if place == "merchant" then
    -- always asked first, with the items (selling cannot be taken back once the buyback list is full)
    local names, total = {}, 0
    for i, e in ipairs(list) do
      total = total + e.value
      if i <= 12 then names[#names + 1] = e.link .. (e.n > 1 and (" x" .. e.n) or "") end
    end
    if #list > 12 then names[#names + 1] = string.format(L["... and %d more"], #list - 12) end
    if not (StaticPopupDialogs and StaticPopup_Show) then sellNow(list); return end
    StaticPopupDialogs["ONEFORALL_BAGADVICE_SELL"] = StaticPopupDialogs["ONEFORALL_BAGADVICE_SELL"] or {
      text = "%s", button1 = ACCEPT or "Accept", button2 = CANCEL or "Cancel", timeout = 0, whileDead = false,
      hideOnEscape = true, preferredIndex = 3,
      OnAccept = function(_, data) if type(data) == "table" then sellNow(data) end end,
    }
    local d = StaticPopup_Show("ONEFORALL_BAGADVICE_SELL",
      string.format(L["Sell these items to the merchant for %s?"], money(total)) .. "\n\n" .. table.concat(names, "\n"))
    if d then d.data = list end
  elseif place == "bank" then
    run(list, function() return place == "bank" end, function(n)
      msg(n == 1 and L["Put 1 item in your bank."] or string.format(L["Put %d items in your bank."], n))
    end)
  elseif place == "mail" then
    -- the "Send Mail" page with the name; the items are attached, sending stays with the player
    if MailFrameTab_OnClick then pcall(MailFrameTab_OnClick, nil, 2) end
    if SendMailNameEditBox and SendMailNameEditBox.SetText then SendMailNameEditBox:SetText(list[1].toName or "") end
    local to = list[1].to
    run(list, function() return place == "mail" and shown(SendMailFrame) end, function(n)
      msg(string.format(n == 1 and L["Attached 1 item for %s - check the name and click Send."] or L["Attached %d items for %s - check the name and click Send."], n == 1 and to or n, to))
    end)
  end
end

local button
local function refresh()
  local p = PLACES[place]
  if not (p and on()) then if button then button:Hide() end return end
  local list = AC.Plan(p.act)
  if #list == 0 then if button then button:Hide() end return end
  if not button then
    button = CreateFrame("Button", "OneForAllBagActionButton", UIParent, "UIPanelButtonTemplate")
    button:SetHeight(24); button:SetFrameStrata("HIGH")
    button:SetScript("OnClick", function() if FLT.SafeCall then FLT.SafeCall("BagActions", click) else click() end end)
    button:SetScript("OnEnter", function(self)
      local pl = PLACES[place]; if not pl then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(L["OneForAll Bag advice"], 1, 0.82, 0)
      local items = AC.Plan(pl.act)
      for i, e in ipairs(items) do
        if i > 20 then GameTooltip:AddLine(string.format(L["... and %d more"], #items - 20), 0.7, 0.7, 0.7); break end
        GameTooltip:AddLine(e.link .. (e.n > 1 and (" x" .. e.n) or ""), 1, 1, 1)
      end
      if place == "mail" then GameTooltip:AddLine(L["Fills the name and attaches the items. You click Send."], 0.7, 0.7, 0.7, true) end
      if place == "merchant" then GameTooltip:AddLine(L["Asks before it sells."], 0.7, 0.7, 0.7, true) end
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  button:SetText("OFA: " .. p.label(list))
  local fs = button.GetFontString and button:GetFontString()
  button:SetWidth(math.max(140, (fs and fs.GetStringWidth and fs:GetStringWidth() or 120) + 28))
  -- under the game's window; with a bag addon that replaces it (window not shown): top of the screen
  local f = p.frame()
  button:ClearAllPoints()
  if shown(f) then button:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, -2) else button:SetPoint("TOP", UIParent, "TOP", 0, -140) end
  button:Show()
end
AC.Refresh = refresh

local waiting = false
local function later() -- bag changes come in bursts
  if waiting then return end
  if not (C_Timer and C_Timer.After) then refresh(); return end
  waiting = true
  C_Timer.After(0.3, function() waiting = false; if FLT.SafeCall then FLT.SafeCall("BagActions", refresh) else pcall(refresh) end end)
end

local OPEN = { MERCHANT_SHOW = "merchant", BANKFRAME_OPENED = "bank", MAIL_SHOW = "mail" }
local CLOSE = { MERCHANT_CLOSED = "merchant", BANKFRAME_CLOSED = "bank", MAIL_CLOSED = "mail" }
local ev = CreateFrame("Frame")
for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "MAIL_SHOW", "MAIL_CLOSED",
  "BAG_UPDATE_DELAYED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event)
  if OPEN[event] then place = OPEN[event]
  elseif CLOSE[event] then
    if place == CLOSE[event] then place = nil end
    if event == "MERCHANT_CLOSED" and StaticPopup_Hide then StaticPopup_Hide("ONEFORALL_BAGADVICE_SELL") end
  elseif not place then return end
  later()
end)
-- the switches (Quality of Life): show / hide at once
if FLT.QoL and FLT.QoL.On then
  FLT.QoL.On("bagAdviceButtons", later)
end

AC._click, AC._ev = click, ev -- tests
