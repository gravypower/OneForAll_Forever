local _, FLT = ...
local L = FLT.L or setmetatable({}, { __index = function(_, k) return k end }) -- (tests without Locales)

-- Bag advice: a line in the tooltip of an item you carry that says what to do with it, to keep the bags empty -
-- "Sell to a merchant (1s 20c)", "Mail it to Smörgi - material for Tailoring", "Keep - needed for a quest in your log" -
-- and a second line with how many of it lie in your bank.
-- Quality of Life > Tooltips > "Bag advice" (QoL key bagAdvice), off by default.
--  * A material of a profession you have: whether a recipe gives you a skill point with it at your skill - a sure one
--    (orange recipe), a likely one (yellow), a rare one (green) - or none any more (grey: sell it).
--  * Only for items you have (in the bags or worn); nothing for items it knows nothing useful about.
--  * It only reads what OneForAll already knows: your professions and those of your other characters, the quest items
--    of Data/QuestDrops.lua, Library Books, the Gear Value, your junk list, merchant prices and (with Auctionator)
--    auction house prices. It is advice, it never sells, mails or destroys anything.
--  * The bank: OneForAllCharDB.bankCount[itemID] = count, read while the bank is open (only while the switch is on).

local BA = {}
FLT.BagAdvice = BA

local OFA = "|cffc8961eOFA|r " -- like the Gear Value line
local COLOR = { sell = { 1, 0.82, 0 }, keep = { 0.55, 0.8, 1 }, use = { 0.25, 1, 0.25 }, drop = { 1, 0.45, 0.35 } }

local function Q(key) return FLT.QoL and FLT.QoL.Get and FLT.QoL.Get(key) end
local function money(c) return FLT.QoL and FLT.QoL.Money and FLT.QoL.Money(c) or tostring(c) end

-- Indexes over the data, each made when first needed ------------------------------------
-- [itemID] = { [profession] = { recipe, ... } }: the recipes that use an item as material
local reagents
local function reagentProfs(id)
  if not reagents then
    reagents = {}
    for prof, list in pairs(FLT.PROFESSION_RECIPES or {}) do
      for _, r in ipairs(list) do
        for _, g in ipairs(r.r or {}) do
          local t = reagents[g[1]]; if not t then t = {}; reagents[g[1]] = t end
          local l = t[prof]; if not l then l = {}; t[prof] = l end
          l[#l + 1] = r
        end
      end
    end
  end
  return reagents[id]
end
-- [recipe item] = { prof, s = spell, req = skill to learn }
local recipes
local function recipeOf(id)
  if not recipes then
    recipes = {}
    for prof, list in pairs(FLT.PROFESSION_RECIPES or {}) do
      for _, r in ipairs(list) do if r.ri then recipes[r.ri] = { prof = prof, s = r.s, req = tonumber(r.req) or 0 } end end
    end
  end
  return recipes[id]
end
-- [itemID] = { questID, ... }: the quests a mob drop is for (FLT.QUEST_DROPS: [npc] = "quest:item,...")
local questItems
local function questsOf(id)
  if not questItems then
    questItems = {}
    for _, s in pairs(FLT.QUEST_DROPS or {}) do
      for qs, is in tostring(s):gmatch("(%d+):(%d+)") do
        local q, item = tonumber(qs), tonumber(is)
        local t = questItems[item]; if not t then t = {}; questItems[item] = t end
        local seen = false
        for _, have in ipairs(t) do if have == q then seen = true; break end end
        if not seen then t[#t + 1] = q end
      end
    end
  end
  return questItems[id]
end
local books
local function bookOf(id)
  if not books then
    books = {}
    for _, b in ipairs(FLT.BOOKS or {}) do if b.itemId then books[b.itemId] = b end end
  end
  return books[id]
end

-- The player ------------------------------------------------------------------------------
-- my skill in a profession, nil without it (read only: FLT.GetProfessionState would make an empty entry)
local function mySkill(prof)
  local all = type(OneForAllCharDB) == "table" and OneForAllCharDB.professions
  local p = type(all) == "table" and all[prof]
  local skill = type(p) == "table" and tonumber(p.skill) or 0
  if skill > 0 then return skill, p.known or {} end
end
-- another character of mine on this realm with the profession (it knows a recipe of it); spell: one that does not
-- know this recipe yet. Returns its name.
local function altWith(prof, spell)
  local all = type(OneForAllDB) == "table" and OneForAllDB.altRecipes
  if type(all) ~= "table" or not (FLT.IsMyChar and FLT.CharOf and FLT.CharLabel) then return nil end
  local realm = GetRealmName and GetRealmName() or ""
  local best
  for key, data in pairs(all) do
    local known = type(data) == "table" and data[prof]
    if type(known) == "table" and next(known) ~= nil and not FLT.IsMyChar(key) and not (spell and known[spell]) then
      local _, r = FLT.CharOf(key, data)
      if not r or r == "" or r == realm then
        local label = FLT.CharLabel(all, key, data)
        if not best or label < best then best = label end -- the same one every time
      end
    end
  end
  return best
end
local function inLog(q)
  if C_QuestLog and C_QuestLog.IsOnQuest then return C_QuestLog.IsOnQuest(q) and true or false end
  return GetQuestLogIndexByID and (GetQuestLogIndexByID(q) or 0) > 0 or false
end
local function questDone(q) return FLT.IsQuestDone and FLT:IsQuestDone(q) or false end
local function questName(q)
  local name = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(q)
  if not name and GetQuestLogIndexByID and GetQuestLogTitle then
    local i = GetQuestLogIndexByID(q)
    if i and i > 0 then name = GetQuestLogTitle(i) end
  end
  return type(name) == "string" and name ~= "" and name or nil
end
local function itemCount(id)
  local n = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id)) or (GetItemCount and GetItemCount(id)) or 0
  return tonumber(n) or 0
end
-- what the tooltip itself says: soulbound, starts a quest (the client's own texts, any language)
local function tipFlags(tt)
  local name = tt and tt.GetName and tt:GetName()
  if not name or not tt.NumLines then return false, false end
  local bound, starts = false, false
  for i = 2, tt:NumLines() do
    local fs = _G[name .. "TextLeft" .. i]
    local t = fs and fs.GetText and fs:GetText()
    if type(t) == "string" and not (FLT.IsSecret and FLT.IsSecret(t)) then
      if t == ITEM_SOULBOUND or t == ITEM_ACCOUNTBOUND or t == ITEM_BNETACCOUNTBOUND then bound = true end
      if t == ITEM_STARTS_QUEST then starts = true end
    end
  end
  return bound, starts
end

-- Selling -----------------------------------------------------------------------------------
-- where an item brings the most: text and kind ("sell" / "drop"). vendor = merchant price of one, count = how many.
local function sell(id, vendor, count, bound, quality)
  local v = (vendor or 0) * count
  local SU = FLT.SkillUp
  local ah = not bound and SU and SU.HasAuctionator and SU.HasAuctionator() and SU.AHPrice and SU.AHPrice(id)
  ah = ah and ah * count * 0.95 or nil -- the auction house keeps 5 %
  if ah and ah > v then
    if v > 0 then return string.format(L["Sell in the auction house (about %s, merchant %s)"], money(ah), money(v)), "sell" end
    return string.format(L["Sell in the auction house (about %s)"], money(ah)), "sell"
  end
  if v > 0 then
    -- no auction price known: green and better gear and materials may still be worth more there
    if not bound and not ah and (quality or 0) >= 2 then
      return string.format(L["Sell in the auction house or to a merchant (%s)"], money(v)), "sell"
    end
    return string.format(L["Sell to a merchant (%s)"], money(v)), "sell"
  end
  if bound then return L["Destroy it (no merchant buys it)"], "drop" end
  return nil
end
local function with(action, reason) return reason and (action .. " - " .. reason) or action end

local function profList(t)
  local names = {}
  for prof in pairs(t) do names[#names + 1] = L[prof] end
  table.sort(names)
  if #names > 2 then return names[1] .. ", " .. names[2] .. " +" .. (#names - 2) end
  return table.concat(names, ", ")
end

-- What a material does for my profession: the best of the recipes that use it, at my skill.
-- rank 6 = a recipe I can make that is orange (a skill point every time), 5 = yellow (most times), 4 = green (rarely),
-- 3 = gives skill points but I have not learned the recipe, 2 = only recipes for a higher skill (req),
-- 1 = used, skill colours unknown, 0 = every recipe is grey (no skill points any more). r = that recipe.
local function skillUse(list, skill, known)
  local best = { rank = 0 }
  local unread = next(known) == nil -- the profession window was never opened: every recipe within the skill counts
  for _, r in ipairs(list) do
    local req, y, g, gr = tonumber(r.req) or tonumber(r.y) or 1, tonumber(r.y) or 0, tonumber(r.g) or 0, tonumber(r.gr) or 0
    local rank
    if gr <= 0 then rank = 1
    elseif skill >= gr then rank = 0
    elseif req > skill then rank = 2
    elseif not (known[r.s] or r.start or unread) then rank = 3
    elseif skill < y then rank = 6
    elseif skill < g then rank = 5
    else rank = 4 end
    -- the better rank; of the recipes for later the one I reach first
    if rank > best.rank or (rank == 2 and best.rank == 2 and req < best.req) then best = { rank = rank, r = r, req = req } end
  end
  return best
end

-- The advice: text, kind (COLOR) or nil ------------------------------------------------------
function BA.Advice(id, link, tt)
  local get = GetItemInfo or (C_Item and C_Item.GetItemInfo)
  if not (id and get) then return nil end
  local name, _, quality, _, minLevel, _, _, _, loc, _, price, classID, subID, bind = get(link or id)
  if not name then return nil end -- not in the client's cache yet
  quality, price, minLevel = quality or 1, price or 0, minLevel or 0
  local count = math.max(1, itemCount(id))
  local tipBound, starts = tipFlags(tt)
  local bound = tipBound or bind == 1 or bind == 4
  local level = UnitLevel and UnitLevel("player") or 0

  -- tools, the hearthstone, fishing poles
  if (FLT.TOOL_ITEMS and FLT.TOOL_ITEMS[id]) or id == 6948 or (classID == 2 and subID == 20) then
    return with(L["Keep"], L["a tool"]), "keep"
  end
  if starts then return with(L["Use it"], L["it starts a quest"]), "use" end

  -- quests: one in the log needs it; all its quests done
  local quests, questsDone = questsOf(id), false
  if quests then
    questsDone = true
    for _, q in ipairs(quests) do
      if inLog(q) then
        local qn = questName(q)
        return with(L["Keep"], qn and string.format(L["needed for your quest \"%s\""], qn) or L["needed for a quest in your log"]), "keep"
      end
      if not questDone(q) then questsDone = false end
    end
  end
  local book = bookOf(id)
  if book and FLT.GetBookState and type(OneForAllCharDB) == "table" and OneForAllCharDB.confirmedDone then
    local state = FLT:GetBookState(book)
    if state ~= "done" and state ~= "manual" then return with(L["Keep"], L["a Library Book to turn in"]), "keep" end
  end
  if classID == 12 or bind == 4 then
    if questsDone then -- every quest it is for is finished: it can go
      if price > 0 then return with(string.format(L["Sell to a merchant (%s)"], money(price * count)), L["its quest is finished"]), "sell" end
      return with(L["Safe to destroy"], L["its quest is finished"]), "drop"
    end
    return with(L["Keep"], L["a quest item"]), "keep"
  end

  -- grey items and the junk list
  local junk = Q("sellJunk") and FLT.QoL.IsJunk and FLT.QoL.IsJunk(id)
  if quality == 0 or junk then
    if price > 0 then return with(string.format(L["Sell to a merchant (%s)"], money(price * count)), junk and L["on your junk list"] or L["junk"]), "sell" end
    return with(L["Destroy it"], L["junk no merchant buys"]), "drop"
  end

  -- gear
  if loc and loc ~= "" and FLT.GEAR_LOC_SLOTS and FLT.GEAR_LOC_SLOTS[loc] then
    local can = FLT.GearCanUse and FLT.GearCanUse(loc, classID, subID)
    local kind = can and FLT.GearValue and FLT.GearValue.Change and FLT.GearValue.Change(id, link) or nil
    if kind == "worn" then return nil end
    if kind == "up" or kind == "new" then
      if minLevel > level then return with(L["Keep (put it in your bank)"], string.format(L["an upgrade at level %d"], minLevel)), "keep" end
      return with(L["Equip it"], L["an upgrade for you"]), "use"
    end
    if can and not kind then return nil end -- no Value yet (no item data): better no advice than a wrong one
    local text, k = sell(id, price, count, bound, quality)
    local why = can and L["not an upgrade for you"] or L["your class cannot use it"]
    if mySkill("Enchanting") and quality >= 2 and (classID == 2 or classID == 4) then
      return with(text and (L["Disenchant it"] .. " / " .. text) or L["Disenchant it"], why), "sell"
    end
    if text then return with(text, why), k end
    return nil
  end

  -- recipes
  local rec = recipeOf(id)
  if rec then
    local skill, known = mySkill(rec.prof)
    if skill and known[rec.s] then
      local text, k = sell(id, price, count, bound, quality)
      if text then return with(text, L["you know this recipe"]), k end
      return nil
    end
    if skill then
      if skill >= rec.req then return with(L["Use it"], L["a recipe you can learn"]), "use" end
      return with(L["Keep (put it in your bank)"], string.format(L["a recipe for %s %d"], L[rec.prof], rec.req)), "keep"
    end
    local alt = not bound and altWith(rec.prof, rec.s)
    if alt then return with(string.format(L["Mail it to %s"], alt), string.format(L["a %s recipe"], L[rec.prof])), "keep" end
    local text, k = sell(id, price, count, bound, quality)
    if text then return with(text, string.format(L["a %s recipe, not your profession"], L[rec.prof])), k end
    return nil
  end

  -- materials of the profession recipes: does it give me a skill point?
  local profs = reagentProfs(id)
  if profs then
    local best, bestProf, greyFor
    for prof, list in pairs(profs) do
      local skill, known = mySkill(prof)
      if skill then
        local u = skillUse(list, skill, known)
        if u.rank == 0 then greyFor = greyFor or prof
        elseif not best or u.rank > best.rank then best, bestProf = u, prof end
      end
    end
    if best then
      local p, rn = L[bestProf], best.r and (FLT.Name and FLT.Name(best.r.n) or best.r.n) or "?"
      if best.rank >= 4 then
        local how = best.rank == 6 and L["a sure skill point in your %s (%s)"] or best.rank == 5 and L["a likely skill point in your %s (%s)"]
          or L["a rare skill point in your %s (%s)"]
        return with(L["Keep (put spare ones in your bank)"], string.format(how, p, rn)), "use"
      elseif best.rank == 3 then
        return with(L["Keep (put spare ones in your bank)"], string.format(L["skill points in your %s once you learn %s"], p, rn)), "keep"
      elseif best.rank == 2 then
        return with(L["Keep (put it in your bank)"], string.format(L["for your %s from skill %d (%s)"], p, best.req, rn)), "keep"
      end
      return with(L["Keep (put spare ones in your bank)"], string.format(L["material for your %s"], p)), "keep"
    end
    if not bound then
      for prof in pairs(profs) do
        local alt = altWith(prof)
        if alt then return with(string.format(L["Mail it to %s"], alt), string.format(L["material for %s"], L[prof])), "keep" end
      end
    end
    local text, k = sell(id, price, count, bound, 2) -- materials: the auction house first
    if text then
      if greyFor then return with(text, string.format(L["no more skill points in your %s from it"], L[greyFor])), k end
      return with(text, string.format(L["material for %s, not your profession"], profList(profs))), k
    end
    return nil
  end

  -- the rest by item class
  if classID == 0 then
    if minLevel > level then return with(L["Keep (put it in your bank)"], string.format(L["usable at level %d"], minLevel)), "keep" end
    return with(L["Keep"], L["a consumable you can use"]), "keep"
  end
  if classID == 13 then return with(L["Keep"], L["a key"]), "keep" end
  if classID == 7 or (classID == 15 and (subID == 0 or subID == 4)) then
    local text, k = sell(id, price, count, bound, classID == 7 and 2 or quality)
    if text then return text, k end
  end
  return nil
end

-- The bank -----------------------------------------------------------------------------------
local function numSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end
local function slotItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local i = C_Container.GetContainerItemInfo(bag, slot)
    if type(i) == "table" then return i.itemID, i.stackCount or 1 end
    return nil
  end
  if GetContainerItemInfo then
    local _, n, _, _, _, _, itemLink, _, _, id = GetContainerItemInfo(bag, slot)
    return id or (itemLink and tonumber(itemLink:match("item:(%d+)"))), n or 1
  end
end
local bankOpen = false
-- every item of the bank with its count; only while the bank can be read, so a closed bank never empties the list
local function scanBank()
  if not Q("bagAdvice") or type(OneForAllCharDB) ~= "table" then return end
  local bags = FLT.CraftList and FLT.CraftList.BANK_BAGS or { -1, 5, 6, 7, 8, 9, 10, 11 }
  if numSlots(bags[1]) <= 0 then return end
  local t = {}
  for _, bag in ipairs(bags) do
    for slot = 1, numSlots(bag) do
      local id, n = slotItem(bag, slot)
      if id then t[id] = (t[id] or 0) + (n or 1) end
    end
  end
  OneForAllCharDB.bankCount = t
end
function BA.InBank(id)
  local t = type(OneForAllCharDB) == "table" and OneForAllCharDB.bankCount
  return type(t) == "table" and tonumber(t[id]) or 0
end

-- The tooltip (QoL.lua addItemLines) ---------------------------------------------------------
function BA.TooltipLine(tt, id, link)
  if not Q("bagAdvice") or not id or itemCount(id) <= 0 then return end
  local text, kind = BA.Advice(id, link, tt)
  if text then
    local c = COLOR[kind] or COLOR.keep
    tt:AddLine(OFA .. text, c[1], c[2], c[3], true)
  end
  local bank = BA.InBank(id)
  if bank > 0 then tt:AddLine(OFA .. string.format(L["%d more in your bank"], bank), 0.7, 0.7, 0.7) end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "BAG_UPDATE_DELAYED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
  if event == "BANKFRAME_OPENED" then bankOpen = true end
  if bankOpen then
    if FLT.SafeCall then FLT.SafeCall("BagAdvice", scanBank) else pcall(scanBank) end
  end
  if event == "BANKFRAME_CLOSED" then bankOpen = false end
end)

BA._scanBank, BA._sell = scanBank, sell -- tests
