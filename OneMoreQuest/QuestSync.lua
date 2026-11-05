-- One More Quest: quest sync (section 6)
-- A quest is shared exactly once, one second after it was accepted (decision 128). When
-- sharing does not work it is not tried again, and there is no card for quests. The only
-- other trigger is a new group member: then everybody shares in turn (player 1, then
-- player 2 ...), each quest tried once per round.
-- Inside a dungeon or raid nothing is shared automatically (decision 409): quests accepted there are
-- not pushed, and a round that falls inside (a dad reloads or reconnects) waits until I am outside
-- again. In combat a waiting push is held until the fight is over.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local SHARE_WAIT = 1            -- seconds between accepting a quest and sharing it
local PUSH_SPACING = 3          -- seconds between two pushed quests
local ARM_SECONDS = 30          -- how long a receiver accepts a announced quest
local LEVEL_GAP = 5             -- automatic sharing only between dads at most this many levels apart (decision 211)
local SEND_INTERVAL = 30        -- seconds between full quest lists
local CHANGE_DELAY = 0.2        -- seconds to wait after the quest log changed
local ROUND_DELAY = 5           -- seconds after the last newcomer before a round starts
local HANDOFF_AFTER = 3         -- seconds after the last push until the next player starts
local HANDOFF_TIMEOUT = 60      -- the next player starts anyway after this long
local ASK_WAIT = 2              -- seconds to wait for the answers "which of these can you take" (decision 297)

local Q = {}
OMQ.QuestSync = Q

local myIds, myTitles = {}, {}        -- questID -> true / title
local lastIds                         -- ids of the last list we sent
local pushQueue = {}
local armed = {}                      -- questID -> expires at (GetTime)
local received = {}                   -- questID -> true: arrived by a share, not accepted by us
local changeDue
local nextPushAt = 0
local roundStartAt                    -- a round starts at this time (debounced)
local round                           -- { waitFor = guid or nil, started = bool, deadline, finishAt }
local inRange                         -- defined below (decision 211)
local doneAt = {}                     -- guid -> time we heard "QD" from that player
local roundAfterInstance              -- a round was due while I was inside a dungeon (decision 409)

-- Inside a dungeon or raid instance? No automatic sharing there (decision 409).
local function inInstance()
    if not IsInInstance then return false end
    local ok, inside, kind = pcall(IsInInstance)
    if not ok or not inside then return false end
    return kind == "party" or kind == "raid"
end
Q.InInstance = inInstance

local function inCombat()
    if InCombatLockdown and InCombatLockdown() then return true end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    return false
end

----------------------------------------------------------------------
-- Own quest log
----------------------------------------------------------------------
function Q:ReadLog()
    local ids, titles = {}, {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return ids, titles end
    local num = C_QuestLog.GetNumQuestLogEntries()
    for i = 1, num do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden and info.questID and info.questID > 0 then
            ids[info.questID] = true
            titles[info.questID] = info.title
        end
    end
    return ids, titles
end

local function idList(ids)
    local t = {}
    for id in pairs(ids) do t[#t + 1] = id end
    table.sort(t)
    return table.concat(t, ",")
end

local function sameSet(a, b)
    if not a or not b then return false end
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

----------------------------------------------------------------------
-- Messages
----------------------------------------------------------------------
-- "Q": whole quest list of the sender (so everybody knows who lacks what)
local function sendList()
    local me = OMQ:GetSelf()
    if not me or not OMQ:GetChannel() then return end
    OMQ:Send("Q", me.guid, idList(myIds))
end

local function handleList(fields)
    local guid, list = fields[1], fields[2] or ""
    local u = guid and OMQ.users[guid]
    if not u then return end
    local set = {}
    for id in list:gmatch("%d+") do set[tonumber(id)] = true end
    u.quests = set
    u.questsAt = GetTime()
end
OMQ:RegisterMessage("Q", handleList)

-- "QS": a quest is about to be shared with you; accept it when it arrives. Only from a dad within
-- 5 levels of you (decision 211); from a dad further away the game's normal window stays.
local function handleShareNotice(fields)
    local id, from = tonumber(fields[1]), fields[2]
    if not id or not OMQ:QuestShareOn() then return end
    if from and from ~= "" and not inRange(from) then return end
    armed[id] = GetTime() + ARM_SECONDS
end
OMQ:RegisterMessage("QS", handleShareNotice)

-- "QD": that player has finished his turn of the sync round
local function handleTurnDone(fields)
    local guid = fields[1]
    if not guid then return end
    doneAt[guid] = GetTime()
    if round and not round.started and round.waitFor == guid then Q:BeginTurn() end
end
OMQ:RegisterMessage("QD", handleTurnDone)

----------------------------------------------------------------------
-- Class quests and quests that cannot be pushed are never shared
----------------------------------------------------------------------
local function isClassQuest(questID)
    local info = C_QuestLog and C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
    if type(info) ~= "table" then return false end
    local classTag = Enum and Enum.QuestTag and Enum.QuestTag.Class
    if classTag and info.tagID == classTag then return true end
    if type(info.tagName) == "string" and type(CLASS) == "string" and info.tagName == CLASS then return true end
    return false
end
Q.IsClassQuest = isClassQuest

local function pushable(questID)
    if isClassQuest(questID) then return false end
    if C_QuestLog and C_QuestLog.IsPushableQuest then return C_QuestLog.IsPushableQuest(questID) end
    return true
end

-- Level of a dad: from his party unit, else the level he sent with his gear
local function levelOf(guid)
    local me = OMQ:GetSelf()
    if me and guid == me.guid then
        local l = UnitLevel and UnitLevel("player")
        return type(l) == "number" and l or nil
    end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitGUID and UnitGUID(unit) == guid then
            local l = UnitLevel and UnitLevel(unit)
            if type(l) == "number" and l > 0 and not (issecretvalue and issecretvalue(l)) then return l end
        end
    end
    local u = OMQ.users[guid]
    return u and tonumber(u.level) or nil
end
Q.LevelOf = levelOf

-- Within 5 levels of me? Unknown levels do not block. The quest level does not matter.
inRange = function(guid)
    local me = OMQ:GetSelf()
    local a, b = me and levelOf(me.guid), levelOf(guid)
    if not a or not b then return true end
    return math.abs(a - b) <= LEVEL_GAP
end
Q.InRange = inRange
Q.LEVEL_GAP = LEVEL_GAP

-- Does any addon user in the group within 5 levels lack this quest (as far as we know)?
local function somebodyLacks(id)
    for guid, u in pairs(OMQ.users) do
        if u.quests and OMQ:IsOnline(u) and not u.quests[id] and inRange(guid) then return true end
    end
    return false
end

Q.SomebodyLacks = function(id) return somebodyLacks(id) end

local function queuePush(id)
    pushQueue[#pushQueue + 1] = { id = id, step = 1, at = GetTime() }
end

----------------------------------------------------------------------
-- Accepting a quest: share it once, one second later
----------------------------------------------------------------------
function Q:Refresh(force)
    local ids, titles = self:ReadLog()
    local added
    if lastIds then
        for id in pairs(ids) do
            if not lastIds[id] then added = added or {}; added[#added + 1] = id end
        end
    end
    myIds, myTitles = ids, titles
    if force or not sameSet(ids, lastIds) then
        lastIds = ids
        sendList()
        OMQ:Fire("QUESTS_CHANGED")
        if added then self:ShareNew(added) end
    end
end

-- Quests that reached me through a share are not passed on. Quests nobody lacks, class
-- quests and unshareable quests are skipped. There is no second attempt.
function Q:ShareNew(added)
    if not OMQ:QuestShareOn() or not OMQ:GetChannel() then return end
    local inside = inInstance()
    table.sort(added)
    for _, id in ipairs(added) do
        if received[id] then
            received[id] = nil
        elseif not inside and pushable(id) and somebodyLacks(id) then
            queuePush(id)
        end
    end
end

local function doPush(id)
    if C_QuestLog and C_QuestLog.SetSelectedQuest then C_QuestLog.SetSelectedQuest(id) end
    if QuestLogPushQuest then QuestLogPushQuest() end
end

----------------------------------------------------------------------
-- The sync round after a newcomer: player 1 first, then player 2 ...
----------------------------------------------------------------------
local function turnOrder()
    local me = OMQ:GetSelf()
    local list = {}
    if me then list[#list + 1] = me.guid end
    for guid, u in pairs(OMQ.users) do
        if OMQ:IsOnline(u) and guid ~= (me and me.guid) then list[#list + 1] = guid end
    end
    table.sort(list)
    return list
end

function Q:StartRound()
    round = nil
    if not OMQ:QuestSyncOn() or not OMQ:GetChannel() then return end
    local me = OMQ:GetSelf()
    if not me then return end
    if inInstance() then roundAfterInstance = true; return end    -- after the dungeon (decision 409)
    local order = turnOrder()
    local mine
    for i, guid in ipairs(order) do if guid == me.guid then mine = i end end
    round = { started = false, waitFor = mine and mine > 1 and order[mine - 1] or nil,
              deadline = GetTime() + HANDOFF_TIMEOUT }
    -- the player before me may have finished already
    local heard = round.waitFor and doneAt[round.waitFor]
    if not round.waitFor or (heard and GetTime() - heard < HANDOFF_TIMEOUT) then self:BeginTurn() end
end

-- My turn: every quest of mine that a dad lacks AND can take is shared once (decision 297).
-- First I ask the dads which of these quests they can take (not done before, pre-quests done, level,
-- faction, race, class: NextQuest.Acceptable); a dad who does not answer (older addon) counts as "yes".
function Q:BeginTurn()
    if not round or round.started then return end
    round.started = true
    self:Refresh(true)
    if OMQ:QuestShareOn() then
        local ids = {}
        for id in pairs(myIds) do
            if pushable(id) and somebodyLacks(id) then ids[#ids + 1] = id end
        end
        table.sort(ids)
        if #ids == 0 then return end
        local NQ = OMQ.NextQuest
        local me = OMQ:GetSelf()
        if not (NQ and NQ._ids and me) then
            for _, id in ipairs(ids) do queuePush(id) end
            return
        end
        round.asking = { reqid = tostring(math.random(100000, 999999)), ids = ids, at = GetTime(), replies = {} }
        OMQ:Send("QA", round.asking.reqid, me.guid, NQ._ids(ids, 40))
    end
end

-- the dads in range who lack the quest and could take it (no answer: assumed yes)
local function somebodyCanTake(id, replies)
    for guid, u in pairs(OMQ.users) do
        if u.quests and OMQ:IsOnline(u) and not u.quests[id] and inRange(guid) then
            local r = replies[guid]
            if r == nil or r[id] then return true end
        end
    end
    return false
end
Q.SomebodyCanTake = somebodyCanTake

local function askDone(now)
    local a = round and round.asking
    if not a then return false end
    local all = true
    local me = OMQ:GetSelf()
    for guid, u in pairs(OMQ.users) do
        if (not me or guid ~= me.guid) and OMQ:IsOnline(u) and inRange(guid) and not a.replies[guid] then all = false end
    end
    if not all and now - a.at < ASK_WAIT then return false end
    round.asking = nil
    for _, id in ipairs(a.ids) do
        if somebodyCanTake(id, a.replies) then queuePush(id) end
    end
    return true
end

-- "QA": which of these quests can you take? "QB": these ones (decision 297)
OMQ:RegisterMessage("QA", function(fields)
    local reqid, from, list = fields[1], fields[2], fields[3]
    local me = OMQ:GetSelf()
    local NQ = OMQ.NextQuest
    if not (reqid and me and NQ and NQ.Acceptable) or from == me.guid then return end
    local log = Q:ReadLog()
    local can = {}
    for id in pairs(NQ._set(list)) do
        if NQ.Acceptable(id, nil, log) then can[#can + 1] = id end
    end
    table.sort(can)
    OMQ:Send("QB", reqid, me.guid, NQ._ids(can, 40))
end)
OMQ:RegisterMessage("QB", function(fields)
    local reqid, from, list = fields[1], fields[2], fields[3]
    local a = round and round.asking
    local NQ = OMQ.NextQuest
    if not (a and NQ and reqid == a.reqid and from) then return end
    a.replies[from] = NQ._set(list)
end)

local function updateRound(now)
    if roundStartAt and now >= roundStartAt then
        roundStartAt = nil
        Q:StartRound()
    end
    if not round then return end
    if round.asking and not askDone(now) then return end
    if not round.started then
        if now >= round.deadline then Q:BeginTurn() end
    elseif #pushQueue == 0 then
        round.finishAt = round.finishAt or (now + HANDOFF_AFTER)
        if now >= round.finishAt then
            round = nil
            local me = OMQ:GetSelf()
            if me then OMQ:Send("QD", me.guid) end
        end
    else
        round.finishAt = nil
    end
end

local function processQueues()
    local now = GetTime()
    if changeDue and now >= changeDue then changeDue = nil; Q:Refresh() end
    -- inside a dungeon: pending pushes are dropped, a due round waits for the way out (decision 409)
    local inside = inInstance()
    if inside then
        if #pushQueue > 0 then pushQueue = {} end
        if round then round = nil; roundAfterInstance = true end
    elseif roundAfterInstance and not roundStartAt then
        roundAfterInstance = nil
        roundStartAt = now + ROUND_DELAY
    end
    -- pushes: announce first, push SHARE_WAIT seconds later; held during a fight
    local item = pushQueue[1]
    local fighting = item and inCombat()
    if fighting and item.step == 2 then item.step = 1 end         -- announce again after the fight
    if item and not fighting and now >= item.at and now >= nextPushAt then
        if item.step == 1 then
            local me = OMQ:GetSelf()
            OMQ:Send("QS", item.id, me and me.guid or "")
            item.step, item.at = 2, now + SHARE_WAIT
        else
            table.remove(pushQueue, 1)
            local ok, err = pcall(doPush, item.id)
            if not ok then OMQ:Error("quest push", err) end
            nextPushAt = now + PUSH_SPACING
        end
    end
    updateRound(now)
end

----------------------------------------------------------------------
-- Receiving: accept an announced quest silently
----------------------------------------------------------------------
local function onQuestDetail()
    if not OMQ:QuestShareOn() then return end
    local id = GetQuestID and GetQuestID()
    local expires = id and armed[id]
    if expires and GetTime() <= expires then
        armed[id] = nil
        received[id] = true
        AcceptQuest()
        if CloseQuest then CloseQuest() end
    end
end

local function onAcceptConfirm()
    if not OMQ:QuestShareOn() then return end
    for id, expires in pairs(armed) do
        if GetTime() <= expires then
            armed[id] = nil
            received[id] = true
            if ConfirmAcceptQuest then ConfirmAcceptQuest() end
            if StaticPopup_Hide then StaticPopup_Hide("QUEST_ACCEPT") end
            return
        end
    end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local frame = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_DETAIL",
                     "QUEST_ACCEPT_CONFIRM" }) do
    frame:RegisterEvent(e)
end

frame:SetScript("OnEvent", function(_, event)
    local ok, err = pcall(function()
        if event == "QUEST_DETAIL" then
            onQuestDetail()
        elseif event == "QUEST_ACCEPT_CONFIRM" then
            onAcceptConfirm()
        else
            changeDue = GetTime() + CHANGE_DELAY
        end
    end)
    if not ok then OMQ:Error(event, err) end
end)

OMQ:On("DB_READY", function()
    OMQ.db.quests = OMQ.db.quests or {}
    OMQ.db.quests.ignored = OMQ.db.quests.ignored or {}
    OMQ.db.quests.notified = OMQ.db.quests.notified or {}
    OMQ.db.quests.titles = OMQ.db.quests.titles or {}
end)

OMQ:On("READY", function()
    Q:Refresh(true)
    C_Timer.NewTicker(0.3, function() pcall(processQueues) end)
    C_Timer.NewTicker(SEND_INTERVAL, function() pcall(sendList) end)
end)

-- A newcomer needs our list; every newcomer starts a (debounced) sync round.
OMQ:On("USER_JOINED", function()
    sendList()
    roundStartAt = GetTime() + ROUND_DELAY
    round = nil
end)

OMQ:RegisterCommand("quests", function(arg)
    if arg == "sync" then
        roundStartAt = GetTime() + 0.5
        OMQ:Print("sync round starts")
        return
    elseif arg == "auto" then
        OMQ.db.options.autoShare = not (OMQ.db.options.autoShare ~= false)
        OMQ:Fire("SETTINGS_CHANGED", "command")
        OMQ:Print("automatic quest sharing " .. (OMQ.db.options.autoShare and "on" or "off"))
        return
    elseif arg == "tags" then
        for id in pairs(myIds) do
            local info = C_QuestLog and C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(id)
            print(string.format("  %d %s: tag %s '%s', class quest: %s, pushable: %s", id, tostring(myTitles[id]),
                tostring(info and info.tagID), tostring(info and info.tagName), tostring(isClassQuest(id)),
                tostring(pushable(id))))
        end
        return
    end
    Q:Refresh()
    local n = 0
    for _ in pairs(myIds) do n = n + 1 end
    OMQ:Print(string.format("quest sync %s, %d quests in your log", OMQ.db.options.questSync and "on" or "off", n))
    print("  automatic sharing " .. (OMQ.db.options.autoShare ~= false and "on" or "off")
        .. (inInstance() and " (paused in this dungeon)" or ""))
    for guid, u in pairs(OMQ.users) do
        local count = 0
        for _ in pairs(u.quests or {}) do count = count + 1 end
        print(string.format("  %s: %s quests known", u.name or "?", u.quests and count or "no"))
    end
    print("  /omq quests sync | auto | tags")
end, "quest sync status, start a sync round, class quest check")
