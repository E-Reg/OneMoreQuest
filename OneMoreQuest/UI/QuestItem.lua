-- One More Quest: quest item bar along the group quest tracker (decisions 354, 355)
-- The objective tracker is hidden, so its click buttons for quest items are gone. Every usable quest item
-- in my bags gets a secure button: in a row under the power bar of the player frame while the tracker card
-- is hidden, in a column right of the card while it is on screen (decision 355).
-- Left click uses the item. Right click hides that item until I use it myself the next time (from the
-- bags or a bar); hidden items are kept in OMQDB.questItemHidden.
-- Which items: for every quest of my log the game's quest item (GetQuestLogSpecialItemInfo) and the items
-- of Data/QuestItems.lua (source item, required source items and item objectives of class Quest, from
-- QuestieDB), then every other item of class Quest in the bags. An item counts when it is in the bags and
-- has an on-use spell (the game's own quest item needs no spell). The items of a finished quest (all
-- objectives done, not yet turned in) are left out.
-- Combat: secure buttons cannot be shown, hidden, moved or given another item in combat. So every item has
-- two buttons, one in the row under the player frame and one in the column next to the card, both on
-- UIParent and never anchored to the card, so the card stays free to come and go. Out of combat only the
-- button of the current place is shown. At the start of a fight (PLAYER_REGEN_DISABLED, before the
-- lockdown) the other one is shown too, invisible (alpha 0): when the card opens or goes in combat, only
-- the alpha changes, which the game allows, and the icons are at once where the card says. The invisible
-- button ignores the right click and shows no tooltip. The list itself stays as it is in combat (an item
-- right-clicked away or used up is dimmed); the buttons are rebuilt as soon as the combat ends.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local Q = {}
OMQ.QuestItem = Q

local SIZE, GAP, MAX = 30, 4, 10
local DIM = 0.4
local QUEST_CLASS = 12
-- the card is at least 380 wide and grows by 60 per dad over four (UI/QuestTracker.lua)
local CARD_MIN, CARD_BASE, CARD_COL = 380, 144, 60

local PLACES = { "player", "tracker" }
local sets = { player = {}, tracker = {} }   -- the secure buttons per place, reused
local list = {}              -- { { item, qid } } the buttons hold, in order
local pending = false        -- the column has to change once the combat ends
local layout = nil           -- "tracker" or "player": the place whose buttons are visible
local armed = false          -- both places shown for the fight (alpha decides which one is seen)
local moveMode = false

local function isSecret(v) return issecretvalue and issecretvalue(v) or false end
local function inCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function num(v) return type(v) == "number" and not isSecret(v) and v or nil end

local function hiddenSet()
    if not OMQ.db then return {} end
    OMQ.db.questItemHidden = OMQ.db.questItemHidden or {}
    return OMQ.db.questItemHidden
end
function Q.IsHidden(id) return hiddenSet()[id] == true end

----------------------------------------------------------------------
-- Items (C_ versions with the old globals as fallback)
----------------------------------------------------------------------
local function itemCount(id)
    local f = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not f then return 0 end
    local ok, n = pcall(f, id)
    return ok and num(n) or 0
end

-- the on-use spell: name and spell id, or nil
local function itemSpell(id)
    local f = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    if not f then return nil end
    local ok, name, spellID = pcall(f, id)
    if not ok or isSecret(name) or isSecret(spellID) then return nil end
    if not (name or spellID) and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, id)        -- not cached yet: the next look finds it
    end
    if not (name or spellID) then return nil end
    return name or spellID, num(spellID)
end
Q._itemSpell = itemSpell

local function itemIcon(id)
    local f = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    if f then
        local ok, t = pcall(f, id)
        if ok and t and not isSecret(t) then return t end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function itemClass(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, _, _, _, _, _, classID = pcall(f, id)
    return ok and num(classID) or nil
end

local function logIndex(qid)
    local CQ = C_QuestLog
    local f = (CQ and CQ.GetLogIndexForQuestID) or GetQuestLogIndexByID
    if not f then return nil end
    local ok, i = pcall(f, qid)
    i = ok and num(i)
    return i and i > 0 and i or nil
end

-- the game's own quest item of a quest: item id or nil
function Q.SpecialItem(qid)
    if not GetQuestLogSpecialItemInfo then return nil end
    local i = logIndex(qid)
    if not i then return nil end
    local ok, link = pcall(GetQuestLogSpecialItemInfo, i)
    if not ok or type(link) ~= "string" or isSecret(link) then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local function questOrder()
    local mine = OMQ.QTrack and OMQ.QTrack:Mine() or {}
    local ids = {}
    for qid in pairs(mine) do ids[#ids + 1] = qid end
    table.sort(ids, function(a, b) return (logIndex(a) or a) < (logIndex(b) or b) end)
    return ids, mine
end

-- every usable quest item in the bags, hidden ones too: { { item, qid } } in quest log order, then the rest
-- a quest of my log that is finished (all objectives done, not yet turned in)
function Q.QuestDone(qid)
    local CQ = C_QuestLog
    if CQ and CQ.IsComplete then
        local ok, v = pcall(CQ.IsComplete, qid)
        if ok and v == true and not isSecret(v) then return true end
    end
    local m = OMQ.QTrack and OMQ.QTrack:Mine()[qid]
    return m and OMQ.QTrack.Complete(m.counts) and true or false
end

-- every usable quest item in the bags, hidden ones too: { { item, qid } } in quest log order, then the rest.
-- The items of a finished quest go (decision 355), unless an open quest needs the same item.
function Q.All()
    local out, seen, done = {}, {}, {}
    local function add(id, qid, special)
        if id and not seen[id] and itemCount(id) > 0 and (special or itemSpell(id)) then
            seen[id] = true
            out[#out + 1] = { item = id, qid = qid }
        end
    end
    local ids = questOrder()
    for _, qid in ipairs(ids) do
        local special, data = Q.SpecialItem(qid), (OMQ.QuestItems or {})[qid] or {}
        if Q.QuestDone(qid) then
            if special then done[special] = true end
            for _, id in ipairs(data) do done[id] = true end
        else
            add(special, qid, true)
            for _, id in ipairs(data) do add(id, qid) end
        end
    end
    local Ct = C_Container
    if Ct and Ct.GetContainerNumSlots and Ct.GetContainerItemID then
        for bag = 0, OMQ.LastBag() do
            local okN, n = pcall(Ct.GetContainerNumSlots, bag)
            for slot = 1, (okN and num(n)) or 0 do
                local okI, id = pcall(Ct.GetContainerItemID, bag, slot)
                id = okI and num(id)
                if id and not seen[id] and not done[id] and itemClass(id) == QUEST_CLASS then add(id, nil) end
            end
        end
    end
    return out
end

-- what the column should hold right now
function Q.Wanted()
    if moveMode or not OMQ:Master("group") then return {} end
    local out = {}
    for _, e in ipairs(Q.All()) do
        if not Q.IsHidden(e.item) and #out < MAX then out[#out + 1] = e end
    end
    return out
end

----------------------------------------------------------------------
-- The buttons
----------------------------------------------------------------------
local attrs = {}             -- [button index] = { type1, item1 }, for /omq questitem and the tests

local function setAttr(i, k, v)
    attrs[i] = attrs[i] or {}
    attrs[i][k] = v
    for _, p in ipairs(PLACES) do sets[p][i]:SetAttribute(k, v) end
end

local function questTitle(qid)
    local m = qid and OMQ.QTrack and OMQ.QTrack:Mine()[qid]
    return m and m.title
end

local function makeButton(place, i)
    local name = place == "player" and ("OneMoreQuestQuestItem" .. i) or ("OneMoreQuestQuestItemTracker" .. i)
    local b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate")
    b:SetSize(SIZE, SIZE)
    b:SetFrameStrata("MEDIUM")
    if b.SetFrameLevel then b:SetFrameLevel(20) end
    -- the secure template fires on mouse down or up depending on ActionButtonUseKeyDown
    b:RegisterForClicks("AnyUp", "AnyDown")
    local edge = b:CreateTexture(nil, "BACKGROUND")
    edge:SetPoint("TOPLEFT", -1, 1); edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0.89, 0.71, 0.29, 1)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    pcall(function()
        b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
        b.cd:SetAllPoints()
    end)
    b.index, b.place = i, place
    -- only the left button uses the item (type1); the right button hides it
    b:SetScript("PostClick", function(self, button, down)
        if button == "RightButton" and not down and self.place == layout then Q:Dismiss(self.index) end
    end)
    b:SetScript("OnEnter", function(self)
        local e = list[self.index]
        if not (GameTooltip and e) or self.place ~= layout then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(e.item)
        else GameTooltip:SetHyperlink("item:" .. e.item) end
        local t = questTitle(e.qid)
        if t then GameTooltip:AddLine("Quest item for: " .. t, 0.72, 0.63, 0.42) end
        GameTooltip:AddLine("Left click: use - right click: hide until you use it again", 0.66, 0.69, 0.73)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:Hide()
    sets[place][i] = b
    return b
end

-- the top right corner of the column: right of the widest card the group can have, at the card's top
local function origin()
    local card = OMQ.QTrackFrame and OMQ.QTrackFrame:Frame()
    local left, top = card and num(card:GetLeft()), card and num(card:GetTop())
    local n = OMQ.QTrack and #OMQ.QTrack:Columns() or 1
    if n > 5 then n = 5 end
    local width = math.max(CARD_MIN, CARD_BASE + n * CARD_COL)
    if left and top then return left + width + GAP, top end
    return nil
end

-- the player frame's power bar (mana, rage, energy): the row of icons hangs under it
function Q.PowerBar()
    local pf = _G.PlayerFrame
    if not pf or (pf.IsForbidden and pf:IsForbidden()) then return nil, "no PlayerFrame" end
    if type(_G.PlayerFrame_GetManaBar) == "function" then
        local ok, bar = pcall(_G.PlayerFrame_GetManaBar)
        if ok and type(bar) == "table" then return bar, "PlayerFrame_GetManaBar" end
    end
    if type(_G.PlayerFrameManaBar) == "table" then return _G.PlayerFrameManaBar, "PlayerFrameManaBar" end
    return pf, "PlayerFrame"
end

-- where the icons sit: next to the card while it is on screen, else in a row under the player frame
function Q.Layout()
    local card = OMQ.QTrackFrame and OMQ.QTrackFrame:Frame()
    if card and card:IsShown() then return "tracker" end
    return "player"
end

local function place(b, i, layout)
    b:ClearAllPoints()
    if layout == "player" then
        local bar = Q.PowerBar()
        if bar then
            b:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", (i - 1) * (SIZE + GAP), -GAP)
            return
        end
    end
    local x, top = origin()
    if x then b:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, top - (i - 1) * (SIZE + GAP))
    else b:SetPoint("TOPLEFT", UIParent, "LEFT", CARD_MIN + GAP, 165 - (i - 1) * (SIZE + GAP)) end
end

-- count, cooldown and dimming; allowed in combat
-- count, cooldown, dimming and which place is seen (alpha); allowed in combat
local alphas = {}            -- [button] = alpha set last, for the tests
local function refreshLooks()
    local f = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
    for i, e in ipairs(list) do
        local n = itemCount(e.item)
        local off = n == 0 or Q.IsHidden(e.item)
        local start, dur, enabled
        if f then
            local ok
            ok, start, dur, enabled = pcall(f, e.item)
            start, dur = ok and num(start), ok and num(dur)
        end
        for _, p in ipairs(PLACES) do
            local b = sets[p][i]
            if b then
                b.count:SetText(n > 1 and tostring(n) or "")
                if b.icon.SetDesaturated then b.icon:SetDesaturated(off) end
                local a = p ~= layout and 0 or (off and DIM or 1)
                b:SetAlpha(a)
                alphas[b] = a
                if b.cd and f then
                    if start and dur and dur > 0 and enabled ~= 0 and enabled ~= false then b.cd:SetCooldown(start, dur)
                    elseif b.cd.Clear then b.cd:Clear() end
                end
            end
        end
    end
end

local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i].item ~= b[i].item then return false end end
    return true
end

function Q:Update()
    local want = Q.Wanted()
    if inCombat() then
        -- nothing secure may change now: the place follows the card by the alpha alone (both places are
        -- shown since the start of the fight), the list catches up after the combat
        if armed then layout = Q.Layout() end
        pending = not same(want, list) or (#list > 0 and not armed and Q.Layout() ~= layout)
        refreshLooks()
        return
    end
    pending, armed = false, false
    layout = Q.Layout()
    for i, e in ipairs(want) do
        for _, p in ipairs(PLACES) do
            if not sets[p][i] then makeButton(p, i) end
        end
        if not (list[i] and list[i].item == e.item) or not (attrs[i] and attrs[i].item1) then
            setAttr(i, "type1", "item")
            setAttr(i, "item1", "item:" .. e.item)
            for _, p in ipairs(PLACES) do sets[p][i].icon:SetTexture(itemIcon(e.item)) end
        end
        for _, p in ipairs(PLACES) do
            local b = sets[p][i]
            place(b, i, p)
            if p == layout then b:Show() else b:Hide() end
        end
    end
    for i = #want + 1, #sets.player do
        if attrs[i] and attrs[i].item1 then setAttr(i, "type1", nil); setAttr(i, "item1", nil) end
        for _, p in ipairs(PLACES) do sets[p][i]:Hide() end
    end
    list = want
    refreshLooks()
end

-- the fight starts (PLAYER_REGEN_DISABLED comes before the lockdown): the buttons of the other place are
-- shown too, invisible, so the icons can follow the card in combat by the alpha alone
function Q:Arm()
    if inCombat() then return end
    for i = 1, #list do
        for _, p in ipairs(PLACES) do
            local b = sets[p][i]
            if b then b:Show() end
        end
    end
    armed = true
    refreshLooks()
end

-- the card opened or went: the place follows at once (only the alpha changes, also in combat)
function Q:Follow()
    self:Update()
end

-- right click: the item is hidden until it is used by hand the next time
function Q:Dismiss(i)
    local e = list[i]
    if not e then return end
    hiddenSet()[e.item] = true
    self:Update()
end

-- a cast of mine: a hidden item whose spell this is comes back
function Q:OnCast(spellID)
    spellID = num(spellID)
    if not spellID then return end
    local h = hiddenSet()
    for id in pairs(h) do
        local _, sid = itemSpell(id)
        if sid == spellID then h[id] = nil end
    end
end

function Q:IsMouseOver()
    for _, b in ipairs(sets[layout or "player"]) do
        if b:IsShown() and b.IsMouseOver then
            local ok, v = pcall(b.IsMouseOver, b)
            if ok and v then return true end
        end
    end
    return false
end
function Q:List() return list end
function Q:Pending() return pending end
function Q:CurrentLayout() return layout end
-- buttons the player sees: shown and of the visible place
function Q:Shown()
    local n = 0
    for _, b in ipairs(sets[layout or "player"]) do if b:IsShown() then n = n + 1 end end
    return n
end
function Q:Armed() return armed end
function Q:Alpha(place, i) local b = sets[place][i]; return b and alphas[b] end
function Q:Attr(i, k) return attrs[i] and attrs[i][k] end
function Q:Button(i, place) return sets[place or layout or "player"][i] end

local function update()
    local ok, err = pcall(Q.Update, Q)
    if not ok then OMQ:Error("questitem", err) end
end

----------------------------------------------------------------------
-- /omq questitem: what the game reports for the quest items; "/omq questitem reset" shows hidden ones again
----------------------------------------------------------------------
function Q.Report()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add("quest items: GetQuestLogSpecialItemInfo " .. tostring(GetQuestLogSpecialItemInfo ~= nil)
        .. ", C_Item.GetItemSpell " .. tostring(C_Item and C_Item.GetItemSpell ~= nil)
        .. ", C_Item.GetItemInfoInstant " .. tostring(C_Item and C_Item.GetItemInfoInstant ~= nil)
        .. ", combat " .. tostring(inCombat()))
    local ids, mine = questOrder()
    for _, qid in ipairs(ids) do
        local special = Q.SpecialItem(qid)
        local parts = {}
        for _, id in ipairs((OMQ.QuestItems or {})[qid] or {}) do
            parts[#parts + 1] = id .. " x" .. itemCount(id) .. (itemSpell(id) and " use" or "")
        end
        if special or #parts > 0 then
            add(string.format("%d %s: game item %s, data %s", qid, tostring(mine[qid].title or "?"),
                tostring(special or "none"), #parts > 0 and table.concat(parts, ", ") or "none"))
        end
    end
    local all = Q.All()
    local names = {}
    for _, e in ipairs(all) do
        names[#names + 1] = e.item .. (e.qid and (" (quest " .. e.qid .. ")") or " (bags)") .. (Q.IsHidden(e.item) and " hidden" or "")
    end
    add("usable quest items: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    local _, how = Q.PowerBar()
    add("buttons shown " .. Q:Shown() .. ", placed " .. tostring(layout) .. " (player frame anchor: " .. tostring(how)
        .. "), waits for the end of combat " .. tostring(pending))
    for _, s in ipairs(lines) do OMQ:Print(s) end
    return lines
end
OMQ:RegisterCommand("questitem", function(arg)
    if arg == "reset" then
        if OMQ.db then OMQ.db.questItemHidden = {} end
        OMQ:Print("quest items: every hidden item is shown again")
        update()
        return
    end
    Q.Report()
end, "quest item bar: what the game reports; 'reset' shows hidden items again")

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "BAG_UPDATE_DELAYED", "UNIT_SPELLCAST_SUCCEEDED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit ~= "player" then return end
        Q:OnCast(spellID)
    end
    update()
    if event == "PLAYER_REGEN_DISABLED" then
        local ok, err = pcall(Q.Arm, Q)
        if not ok then OMQ:Error("questitem", err) end
    end
end)

OMQ:On("READY", function()
    update()
    -- the card's own show and hide move the icons at once (the ticker below is the safety net)
    local card = OMQ.QTrackFrame and OMQ.QTrackFrame:Frame()
    if card and card.HookScript then
        local function follow()
            local ok, err = pcall(Q.Follow, Q)
            if not ok then OMQ:Error("questitem", err) end
        end
        pcall(card.HookScript, card, "OnShow", follow)
        pcall(card.HookScript, card, "OnHide", follow)
    end
    -- the card's place and the group size can change: follow them every second
    C_Timer.NewTicker(1, update)
end)
OMQ:On("QTRACK_CHANGED", update)
OMQ:On("SETTINGS_CHANGED", update)
OMQ:On("ROSTER_CHANGED", update)
OMQ:On("MOVE_MODE", function(on) moveMode = on and true or false; update() end)
