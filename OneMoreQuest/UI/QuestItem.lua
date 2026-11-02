-- One More Quest: quest item button next to the group quest tracker card (decision 354)
-- The objective tracker is hidden, so its click buttons for quest items are gone. While the card shows a
-- quest of my log for which I carry a usable quest item, a secure button with that item sits at the
-- right edge of the card; a click uses the item like the button of the objective tracker.
-- Candidates: the game's quest item (GetQuestLogSpecialItemInfo) first, then Data/QuestItems.lua (source
-- item, required source items and item objectives of class Quest, from QuestieDB). A candidate counts when
-- it is in the bags; a database item also needs an on-use spell. A finished quest gets no button, unless
-- the game says its own item is shown when complete.
-- Combat: a secure button cannot be shown, hidden, moved or given another item in combat. It is its own
-- frame on UIParent, never anchored to the card, so the card stays free to come and go in combat. In
-- combat a button that no longer fits the card is dimmed (still usable), and a card that needs a button
-- gets it as soon as the combat ends.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local Q = {}
OMQ.QuestItem = Q

local SIZE, GAP = 30, 4
local DIM = 0.4

local btn, icon, count, cd
local cur = nil              -- { qid, item } that the button holds
local pending = false        -- the button has to change once the combat ends
local dimmed = false
local moveMode = false

local function isSecret(v) return issecretvalue and issecretvalue(v) or false end
local function inCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function num(v) return type(v) == "number" and not isSecret(v) and v or nil end

----------------------------------------------------------------------
-- Items (C_ versions with the old globals as fallback)
----------------------------------------------------------------------
local function itemCount(id)
    local f = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not f then return 0 end
    local ok, n = pcall(f, id)
    return ok and num(n) or 0
end

local function itemSpell(id)
    local f = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    if not f then return nil end
    local ok, name, spellID = pcall(f, id)
    if not ok or isSecret(name) or isSecret(spellID) then return nil end
    if not (name or spellID) and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, id)        -- not cached yet: the next look finds it
    end
    return name or spellID
end

local function itemIcon(id)
    local f = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    if f then
        local ok, t = pcall(f, id)
        if ok and t and not isSecret(t) then return t end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function logIndex(qid)
    local CQ = C_QuestLog
    local f = (CQ and CQ.GetLogIndexForQuestID) or GetQuestLogIndexByID
    if not f then return nil end
    local ok, i = pcall(f, qid)
    i = ok and num(i)
    return i and i > 0 and i or nil
end

-- the game's own quest item: item id and "shown when complete"
function Q.SpecialItem(qid)
    if not GetQuestLogSpecialItemInfo then return nil end
    local i = logIndex(qid)
    if not i then return nil end
    local ok, link, _, _, showWhenComplete = pcall(GetQuestLogSpecialItemInfo, i)
    if not ok or type(link) ~= "string" or isSecret(link) then return nil end
    local id = tonumber(link:match("item:(%d+)"))
    return id, showWhenComplete and not isSecret(showWhenComplete) and true or false
end

local function complete(qid)
    local m = OMQ.QTrack and OMQ.QTrack:Mine()[qid]
    return m and OMQ.QTrack.Complete(m.counts) and true or false
end

-- the item the button shows for a quest of my log, or nil
function Q.Find(qid)
    if not (OMQ.QTrack and OMQ.QTrack:Mine()[qid]) then return nil end
    local done = complete(qid)
    local special, showDone = Q.SpecialItem(qid)
    if special and (not done or showDone) and itemCount(special) > 0 then return special end
    if done then return nil end
    for _, id in ipairs((OMQ.QuestItems or {})[qid] or {}) do
        if id ~= special and itemCount(id) > 0 and itemSpell(id) then return id end
    end
    return nil
end

-- what the card wants right now: quest id and item, or nil
function Q.Wanted()
    local T = OMQ.QTrack
    if moveMode or not (T and T:Shown()) or T:Stamp() then return nil end
    local v = T:View()
    if not v then return nil end
    local item = Q.Find(v.qid)
    if not item then return nil end
    return { qid = v.qid, item = item }
end

----------------------------------------------------------------------
-- The button
----------------------------------------------------------------------
local attrs = {}             -- what the button was given, for /omq questitem and the tests
local function setAttr(k, v)
    attrs[k] = v
    if btn.SetAttribute then btn:SetAttribute(k, v) end
end

local function build()
    btn = CreateFrame("Button", "OneMoreQuestQuestItem", UIParent, "SecureActionButtonTemplate")
    btn:SetSize(SIZE, SIZE)
    btn:SetFrameStrata("MEDIUM")
    if btn.SetFrameLevel then btn:SetFrameLevel(20) end
    -- the secure template fires on mouse down or up depending on ActionButtonUseKeyDown
    btn:RegisterForClicks("AnyUp", "AnyDown")
    local edge = btn:CreateTexture(nil, "BACKGROUND")
    edge:SetPoint("TOPLEFT", -1, 1); edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0.89, 0.71, 0.29, 1)
    icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", -2, 2)
    pcall(function()
        cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
        cd:SetAllPoints()
    end)
    btn:SetScript("OnEnter", function(self)
        if not (GameTooltip and cur) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(cur.item)
        else GameTooltip:SetHyperlink("item:" .. cur.item) end
        local m = OMQ.QTrack:Mine()[cur.qid]
        GameTooltip:AddLine("Quest item for: " .. ((m and m.title) or ("Quest " .. cur.qid)), 0.72, 0.63, 0.42)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    btn:Hide()
end

-- right of the card at the height of its title, in UIParent coordinates (never anchored to the card)
local function place()
    local card = OMQ.QTrackFrame and OMQ.QTrackFrame:Frame()
    local right, top = card and num(card:GetRight()), card and num(card:GetTop())
    btn:ClearAllPoints()
    if right and top then
        btn:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right + GAP, top - 18)
    else
        btn:SetPoint("LEFT", UIParent, "LEFT", 400, 165)
    end
end

local function setDim(on)
    dimmed = on and true or false
    if btn then btn:SetAlpha(dimmed and DIM or 1) end
    if icon and icon.SetDesaturated then icon:SetDesaturated(dimmed) end
end

local function refreshLooks()
    if not (btn and cur) then return end
    local n = itemCount(cur.item)
    count:SetText(n > 1 and tostring(n) or "")
    if icon.SetDesaturated then icon:SetDesaturated(dimmed or n == 0) end
    local f = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
    if cd and f then
        local ok, start, dur, enabled = pcall(f, cur.item)
        start, dur = ok and num(start), ok and num(dur)
        if start and dur and dur > 0 and enabled ~= 0 and enabled ~= false then cd:SetCooldown(start, dur)
        elseif cd.Clear then cd:Clear() end
    end
end

local function same(a, b) return a and b and a.qid == b.qid and a.item == b.item end

function Q:Update()
    local want = Q.Wanted()
    if inCombat() then
        -- nothing secure may change now: dim a button that does not fit, catch up after the combat
        if same(want, cur) then setDim(false); pending = false
        else
            if cur then setDim(true) end
            pending = (want ~= nil) or (cur ~= nil)
        end
        refreshLooks()
        return
    end
    pending = false
    if not want then
        cur = nil
        if btn then setAttr("type1", nil); setAttr("item1", nil); btn:Hide() end
        setDim(false)
        return
    end
    if not btn then build() end
    if not same(want, cur) then
        cur = want
        setAttr("type1", "item")
        setAttr("item1", "item:" .. want.item)
        icon:SetTexture(itemIcon(want.item))
    end
    place()
    setDim(false)
    refreshLooks()
    btn:Show()
end

function Q:IsMouseOver()
    if not (btn and btn:IsShown() and btn.IsMouseOver) then return false end
    local ok, v = pcall(btn.IsMouseOver, btn)
    return ok and v and true or false
end
function Q:State() return cur, pending, btn and btn:IsShown() or false, dimmed end
function Q:Button() return btn end
function Q:Attr(k) return attrs[k] end

local function update()
    local ok, err = pcall(Q.Update, Q)
    if not ok then OMQ:Error("questitem", err) end
end

----------------------------------------------------------------------
-- /omq questitem: what the game reports for the quest items of my log
----------------------------------------------------------------------
function Q.Report()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add("quest items: GetQuestLogSpecialItemInfo " .. tostring(GetQuestLogSpecialItemInfo ~= nil)
        .. ", C_QuestLog.GetLogIndexForQuestID " .. tostring(C_QuestLog and C_QuestLog.GetLogIndexForQuestID ~= nil)
        .. ", C_Item.GetItemSpell " .. tostring(C_Item and C_Item.GetItemSpell ~= nil)
        .. ", GetItemSpell " .. tostring(GetItemSpell ~= nil) .. ", combat " .. tostring(inCombat()))
    local mine = OMQ.QTrack and OMQ.QTrack:Mine() or {}
    local ids = {}
    for qid in pairs(mine) do ids[#ids + 1] = qid end
    table.sort(ids)
    for _, qid in ipairs(ids) do
        local special, showDone = Q.SpecialItem(qid)
        local parts = {}
        for _, id in ipairs((OMQ.QuestItems or {})[qid] or {}) do
            parts[#parts + 1] = id .. " x" .. itemCount(id) .. (itemSpell(id) and " use" or "")
        end
        if special or #parts > 0 then
            add(string.format("%d %s: game item %s%s, data %s -> %s", qid, tostring(mine[qid].title or "?"),
                tostring(special or "none"), showDone and " (shown when complete)" or "",
                #parts > 0 and table.concat(parts, ", ") or "none", tostring(Q.Find(qid) or "no button")))
        end
    end
    if #lines == 1 then add("no quest of the log has a quest item") end
    local c, p, shown = Q:State()
    add("button: " .. (c and (c.item .. " for quest " .. c.qid) or "none") .. ", shown " .. tostring(shown)
        .. ", waits for the end of combat " .. tostring(p))
    for _, s in ipairs(lines) do OMQ:Print(s) end
    return lines
end
OMQ:RegisterCommand("questitem", function() Q.Report() end, "quest item button: what the game reports")

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "BAG_UPDATE_DELAYED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", update)

OMQ:On("READY", function()
    -- the card changes width with the dads and the counts: follow it twice a second
    C_Timer.NewTicker(0.5, function() if cur or OMQ.QTrack:Shown() then update() end end)
end)
OMQ:On("QTRACK_CHANGED", update)
OMQ:On("SETTINGS_CHANGED", update)
OMQ:On("MOVE_MODE", function(on) moveMode = on and true or false; update() end)
