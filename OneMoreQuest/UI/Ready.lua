-- One More Quest: Group Check (decision 140; renamed from "Dungeon check" in 0.33.0, decision 193)
-- A small window that shows, for every dad in the group, the things worth having before a dungeon:
-- durability, free bag slots, drinks (mana classes) and the class item (ammo, poison, soul shards,
-- resurrection seeds, ankh). Only players with the addon are listed. Data is asked for on a button
-- press; every client answers with his own numbers and the viewer applies the thresholds.
--   DC|proto|reqId|dungeonKey                                (question; dungeonKey "-" = general check only)
--   DR|proto|reqId|guid|dur|free|drink|xkey|xcount           (answer; drink "-" = no mana class,
--                                                             xkey A ammo, P poison, S shards, R seeds, K ankh, "-" none)
--   DQ|proto|reqId|guid|dungeonKey|idsInLog|idsDone          (dungeon quests, decision 142; ids separated by ",")
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local R = {}
OMQ.Ready = R

-- A cell is red when the value is below the threshold (generous, decision 140)
local LIMIT = { dur = 50, free = 15, drink = 20, A = 600, P = 20, S = 10, R = 1, K = 1 }
local XLABEL = { A = "Ammo", P = "Poison", S = "Shards", R = "Seeds", K = "Ankh" }
local NO_MANA = { WARRIOR = true, ROGUE = true }
local REFRESH = 15            -- seconds between questions while the window is open
local WAIT = 3                -- seconds until a missing answer shows as "no answer"

-- item ids from memory, not checked in the game (see /omq ready debug)
local DRINKS = { 159, 1179, 1205, 1708, 1645, 8766, 5350, 2288, 2136, 3772, 8077, 8078, 8079, 4791, 19300, 18300 }
local POISONS = { 6947, 6949, 6950, 8926, 8927, 8928, 2892, 2893, 8984, 8985, 20844, 3775, 3776, 5237, 6951,
                  10918, 10920, 10921, 10922 }
local SOUL_SHARD = 6265
local SEEDS = { 17034, 17035, 17036, 17037, 17038, 22147 }
local ANKH = 17030
-- what the auction helper never posts: drinks and class supplies the dads carry on purpose (decision 260)
R.KEEP = {}
for _, list in ipairs({ DRINKS, POISONS, SEEDS, { SOUL_SHARD, ANKH } }) do
    for _, id in ipairs(list) do R.KEEP[id] = true end
end

local function isSecret(v) return issecretvalue and issecretvalue(v) end

----------------------------------------------------------------------
-- Own numbers
----------------------------------------------------------------------
local function bagCounts()
    local counts, free = {}, 0
    local C = C_Container
    if not (C and C.GetContainerNumSlots) then return counts, 0 end
    for bag = 0, OMQ.LastBag() do
        if C.GetContainerNumFreeSlots and bag <= (NUM_BAG_SLOTS or 4) then      -- the reagent bag holds only reagents
            local n, family = C.GetContainerNumFreeSlots(bag)
            if type(n) == "number" and (family == nil or family == 0) then free = free + n end
        end
        for slot = 1, C.GetContainerNumSlots(bag) or 0 do
            local info = C.GetContainerItemInfo and C.GetContainerItemInfo(bag, slot)
            if info and type(info.itemID) == "number" and not isSecret(info.itemID) then
                counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    return counts, free
end

local function sum(counts, ids)
    local n = 0
    for _, id in ipairs(ids) do n = n + (counts[id] or 0) end
    return n
end

-- Required level of an item. WoW Forever has no global GetItemInfo any more (section 13.1), so
-- C_Item.GetItemInfo comes first. It returns nothing until the item is in the client cache: then
-- the item is loaded and nil is returned; the window asks again every 15 seconds (v0.25.2).
local function minLevelOf(id)
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if info then
        local ok, name, _, _, _, minLevel = pcall(info, id)
        if ok and name and type(minLevel) == "number" and not isSecret(minLevel) then return minLevel end
    end
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    return nil
end
R.MinLevelOf = minLevelOf

local function usable(id, level)
    local minLevel = minLevelOf(id)
    if minLevel then return minLevel <= level end
    return true                          -- not in the cache yet: count it until the next check
end

local function lowestDurability()
    local lowest
    for s = 1, 19 do
        local cur, max = GetInventoryItemDurability(s)
        if type(cur) == "number" and type(max) == "number" and max > 0 then
            local pct = cur / max * 100
            if not lowest or pct < lowest then lowest = pct end
        end
    end
    return lowest and math.floor(lowest) or 100
end

-- usable drinks in the bags, nil for classes without mana (the drink alert, decision 189)
local drinkCache, drinkAt = nil, -100
function R.Drinks()
    local _, class = UnitClass("player")
    if NO_MANA[class] then return nil end
    if GetTime() - drinkAt < 3 then return drinkCache end
    local level = UnitLevel("player") or 1
    local counts = bagCounts()
    local n = 0
    for _, id in ipairs(DRINKS) do
        if (counts[id] or 0) > 0 and usable(id, level) then n = n + counts[id] end
    end
    drinkCache, drinkAt = n, GetTime()
    return n
end

-- the best usable drink in the bags (the highest required level), as an item id, or nil (decision 219)
function R.BestDrink()
    local level = UnitLevel("player") or 1
    local counts = bagCounts()
    local best, bestLvl
    for _, id in ipairs(DRINKS) do
        if (counts[id] or 0) > 0 and usable(id, level) then
            local lvl = minLevelOf(id) or 0
            if not best or lvl > bestLvl then best, bestLvl = id, lvl end
        end
    end
    return best
end

function R:Mine()
    local _, class = UnitClass("player")
    local level = UnitLevel("player") or 1
    local counts, free = bagCounts()
    local row = { dur = lowestDurability(), free = free, class = class }
    if not NO_MANA[class] then
        local n = 0
        for _, id in ipairs(DRINKS) do
            if (counts[id] or 0) > 0 and usable(id, level) then n = n + counts[id] end
        end
        row.drink = n
    end
    if class == "HUNTER" then
        local sub, have = nil, nil
        if OMQ.QoL and OMQ.QoL.AmmoStatus then sub, have = OMQ.QoL:AmmoStatus() end
        if sub then row.xkey, row.xcount = "A", have end
    elseif class == "ROGUE" and level >= 20 then
        row.xkey, row.xcount = "P", sum(counts, POISONS)
    elseif class == "WARLOCK" and level >= 10 then
        row.xkey, row.xcount = "S", counts[SOUL_SHARD] or 0
    elseif class == "DRUID" and level >= 20 then
        row.xkey, row.xcount = "R", sum(counts, SEEDS)
    elseif class == "SHAMAN" and level >= 30 then
        row.xkey, row.xcount = "K", counts[ANKH] or 0
    end
    return row
end

----------------------------------------------------------------------
-- Messages
----------------------------------------------------------------------
local answers = {}            -- guid -> { row, at }
local asked = 0               -- time of the last question we sent
local lastReply = -100

-- quest ids of the dungeon that are in my log / already handed in
function R:MyQuests(d)
    local log, done = {}, {}
    local CQ = C_QuestLog
    for _, q in ipairs(d.quests) do
        local ids = { q.id }
        for _, a in ipairs(q.alt or {}) do ids[#ids + 1] = a end
        for _, id in ipairs(ids) do
            local isDone = CQ and CQ.IsQuestFlaggedCompleted and CQ.IsQuestFlaggedCompleted(id)
            if isDone then
                done[id] = true
            else
                local idx = CQ and CQ.GetLogIndexForQuestID and CQ.GetLogIndexForQuestID(id)
                if idx then log[id] = true end
            end
        end
    end
    return log, done
end

-- a quest counts with any of its ids; handed in beats in the log
local function stateOf(q, log, done)
    local ids = { q.id }
    for _, a in ipairs(q.alt or {}) do ids[#ids + 1] = a end
    local inLog = false
    for _, id in ipairs(ids) do
        if done[id] then return "done" end
        if log[id] then inLog = true end
    end
    return inLog and "log" or "none"
end

local function idList(set)
    local t = {}
    for id in pairs(set) do t[#t + 1] = id end
    table.sort(t)
    return #t > 0 and table.concat(t, ",") or "-"
end

local function sendAnswer(reqId, dkey)
    local me = OMQ:GetSelf()
    if not me then return end
    local row = R:Mine()
    OMQ:Send("DR", reqId, me.guid, row.dur, row.free, row.drink or "-", row.xkey or "-", row.xcount or 0)
    local d = dkey and OMQ:DungeonByKey(dkey)
    if d and #d.quests > 0 then
        local log, done = R:MyQuests(d)
        OMQ:Send("DQ", reqId, me.guid, d.key, idList(log), idList(done))
    end
end

OMQ:RegisterMessage("DC", function(f, sender)
    local reqId = f[1]
    if not reqId or reqId == "" then return end
    local now = GetTime()
    if now - lastReply < 2 then return end             -- several questions at once: answer once
    lastReply = now
    pcall(sendAnswer, reqId, f[2])
end)

local function parseIds(text)
    local set = {}
    if text and text ~= "-" then
        for id in string.gmatch(text, "%d+") do set[tonumber(id)] = true end
    end
    return set
end

local qanswers = {}           -- guid -> { key, log, done }
OMQ:RegisterMessage("DQ", function(f)
    local guid = f[2]
    local me = OMQ:GetSelf()
    if not guid or guid == "" or (me and guid == me.guid) then return end
    if not OMQ.users[guid] then return end
    qanswers[guid] = { key = f[3], log = parseIds(f[4]), done = parseIds(f[5]) }
    OMQ:Fire("READY_UPDATED")
end)

OMQ:RegisterMessage("DR", function(f)
    local guid = f[2]
    local me = OMQ:GetSelf()
    if not guid or guid == "" or (me and guid == me.guid) then return end
    if not OMQ.users[guid] then return end             -- only addon users we know
    answers[guid] = { at = GetTime(), row = {
        dur = tonumber(f[3]), free = tonumber(f[4]),
        drink = tonumber(f[5]),                       -- "-" becomes nil
        xkey = (f[6] and f[6] ~= "-" and f[6] ~= "") and f[6] or nil, xcount = tonumber(f[7]),
    } }
    OMQ:Fire("READY_UPDATED")
end)

R.dungeon = nil           -- key of the dungeon the window is about, nil = general check only

function R:Ask()
    asked = GetTime()
    OMQ:Send("DC", string.format("%d", math.floor(GetTime() * 10) % 100000), self.dungeon or "-")
end

-- "done", "log" or "none" for a member and a quest; nil = no answer yet
function R:QuestState(r, q)
    if r.isSelf then
        local d = OMQ:DungeonByKey(self.dungeon)
        local log, done = self:MyQuests(d)
        return stateOf(q, log, done)
    end
    local a = r.guid and qanswers[r.guid]
    if not a or a.key ~= self.dungeon then return nil end
    return stateOf(q, a.log, a.done)
end

----------------------------------------------------------------------
-- Rows and verdict
----------------------------------------------------------------------
local function bad(row)
    local list = {}
    if row.dur and row.dur < LIMIT.dur then list[#list + 1] = "durability" end
    if row.free and row.free < LIMIT.free then list[#list + 1] = "bags" end
    if row.drink and row.drink < LIMIT.drink then list[#list + 1] = "drink" end
    if row.xkey and row.xcount and row.xcount < LIMIT[row.xkey] then list[#list + 1] = XLABEL[row.xkey]:lower() end
    return list
end

-- { name, class, row or nil, state = "ok" | "wait" | "none" } for me and every dad in my group
function R:Rows()
    local out = {}
    local me = OMQ:GetSelf()
    if me then out[1] = { name = me.name, class = me.class, row = self:Mine(), isSelf = true } end
    local others = {}
    for guid, u in pairs(OMQ.users) do
        if (not me or guid ~= me.guid) and OMQ:IsOnline(u) then
            local a = answers[guid]
            others[#others + 1] = { guid = guid, name = u.name, class = u.class, pos = OMQ:GroupPosition(guid) or 9,
                row = a and a.row or nil }
        end
    end
    table.sort(others, function(a, b)
        if a.pos ~= b.pos then return a.pos < b.pos end
        return (a.name or "") < (b.name or "")
    end)
    for _, o in ipairs(others) do
        o.state = o.row and "ok" or ((GetTime() - asked) < WAIT and "wait" or "none")
        out[#out + 1] = o
    end
    if out[1] then out[1].state = "ok" end
    return out
end

function R:Verdict(rows)
    local problems = {}
    for _, r in ipairs(rows) do
        if r.row then
            local b = bad(r.row)
            if #b > 0 then problems[#problems + 1] = (r.name or "?") .. ": " .. table.concat(b, ", ") end
        end
    end
    return problems
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local NAME_W, COL_W, XCOL_W, ROW_H, PAD = 84, 44, 78, 18, 10
local GREY = { 0.45, 0.47, 0.5 }
local RED = { 0.92, 0.36, 0.31 }
local GREEN = { 0.49, 0.78, 0.44 }
local QNAME_W, QCOL_W, QROW_H = 280, 62, 34          -- the dungeon part has more room (decision 193)
local ENT_W = 84
local STATE_TEXT = { done = { "Done", GREEN }, log = { "In log", { 0.89, 0.71, 0.29 } }, none = { "-", GREY } }
local frame, cells, footer, title, qhead, qcells, entrance, qbuttons, prevBtn, nextBtn

-- the dungeons the arrows switch between (decision 256): those of the check bar (my level), plus the open one
function R.Relevant()
    local level = UnitLevel and tonumber((UnitLevel("player"))) or 1
    local list = OMQ.DungeonsForLevel and OMQ:DungeonsForLevel(level) or {}
    local cur, has = R.dungeon, false
    for _, d in ipairs(list) do if d.key == cur then has = true end end
    if cur and not has and OMQ.Dungeons then        -- opened with /omq ready <key>: keep it in its place
        local out = {}
        for _, d in ipairs(OMQ.Dungeons) do
            if d.key == cur then out[#out + 1] = d else
                for _, l in ipairs(list) do if l == d then out[#out + 1] = d end end
            end
        end
        list = out
    end
    return list
end

-- the previous (-1) or next (+1) relevant dungeon, wrapping around
function R:Neighbour(dir)
    local list = R.Relevant()
    if #list < 2 or not self.dungeon then return nil end
    for i, d in ipairs(list) do
        if d.key == self.dungeon then return list[(i - 1 + dir) % #list + 1] end
    end
    return list[1]
end

function R:Step(dir)
    local d = self:Neighbour(dir)
    if not d then return false end
    self.dungeon = d.key
    self:Ask()
    self:Render()
    return true
end

local function classColor(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestReady", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetPoint("CENTER")
    frame:Hide()
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.08, 0.105, 0.97)
    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.48, 0.39, 0.2, 1)
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestReady") end

    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD, -PAD)
    title:SetText("Group Check")
    title:SetTextColor(0.89, 0.71, 0.29)
    -- the entrance line: a click starts the arrow there (decisions 193 and 195; not on the dungeon name)
    entrance = CreateFrame("Button", nil, frame)
    entrance:SetHeight(18)
    entrance.text = entrance:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    entrance.text:SetPoint("LEFT")
    entrance.text:SetJustifyH("LEFT")
    entrance:SetScript("OnClick", function() R:GuideToEntrance() end)
    entrance:SetScript("OnEnter", function(self) R:EntranceTip(self) end)
    entrance:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    entrance:Hide()
    local close = CreateFrame("Button", nil, frame)
    close:SetSize(16, 16)
    close:SetPoint("TOPRIGHT", -6, -6)
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    x:SetAllPoints()
    x:SetText("x")
    x:SetTextColor(0.7, 0.7, 0.75)
    close:SetScript("OnClick", function() frame:Hide() end)
    -- arrows to the previous and next dungeon of my level (decision 256)
    local function arrow(dir)
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(24, 24)
        local base = dir < 0 and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-"
        b:SetNormalTexture(base .. "Up")
        b:SetPushedTexture(base .. "Down")
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        b:SetScript("OnClick", function() R:Step(dir) end)
        b:SetScript("OnEnter", function(self)
            local d = R:Neighbour(dir)
            if not (GameTooltip and d) then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText((dir < 0 and "Previous: " or "Next: ") .. d.name)
            GameTooltip:AddLine("Level " .. d.min .. "-" .. d.max, 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        b:Hide()
        return b
    end
    prevBtn = arrow(-1)
    prevBtn:SetPoint("TOPLEFT", PAD - 6, -(PAD - 6))
    nextBtn = arrow(1)
    nextBtn:SetPoint("TOPRIGHT", close, "TOPLEFT", -2, 4)

    cells = {}
    local heads = { "", "Dur", "Bags", "Drink", "Class item", "To entrance" }
    local xs = { 0, NAME_W, NAME_W + COL_W, NAME_W + COL_W * 2, NAME_W + COL_W * 3, NAME_W + COL_W * 3 + XCOL_W }
    for r = 0, 5 do
        cells[r] = {}
        for c = 1, 6 do
            local fs = frame:CreateFontString(nil, "OVERLAY", r == 0 and "GameFontNormalSmall" or "GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", PAD + xs[c], -(PAD + 22 + r * ROW_H))
            fs:SetWidth(c == 1 and NAME_W - 4 or (c == 5 and XCOL_W or (c == 6 and ENT_W or COL_W - 4)))
            fs:SetJustifyH("LEFT")
            if fs.SetWordWrap then fs:SetWordWrap(false) end
            cells[r][c] = fs
            if r == 0 then fs:SetText(heads[c]); fs:SetTextColor(0.72, 0.63, 0.42) end
        end
    end
    footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetJustifyH("LEFT")
    if footer.SetWordWrap then footer:SetWordWrap(true) end
    footer:SetWidth(NAME_W + COL_W * 3 + XCOL_W)

    qhead = { name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), cols = {} }
    qhead.name:SetText("Dungeon quests")
    qhead.name:SetTextColor(0.72, 0.63, 0.42)
    qhead.name:SetJustifyH("LEFT")
    for c = 1, 5 do
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetWidth(QCOL_W - 4)
        fs:SetJustifyH("LEFT")
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        qhead.cols[c] = fs
    end
    qcells = {}
    qbuttons = {}

    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 1 then return end
        acc = 0
        if GetTime() - asked >= REFRESH then R:Ask() end
        R:Render()
    end)
end

local function setCell(fs, text, color)
    fs:SetText(text)
    fs:SetTextColor(color[1], color[2], color[3])
end

----------------------------------------------------------------------
-- Dungeon entrance and quest starts (decision 193)
----------------------------------------------------------------------
local entCache = {}
local function entrancesOf(key)
    local list = OMQ.DungeonEntrances and OMQ.DungeonEntrances[key]
    if not list then return nil end
    if not entCache[key] then
        local out = {}
        for i, e in ipairs(list) do out[i] = { nil, nil, e[1], e[2], e[3], map = e[1] } end
        entCache[key] = out
    end
    return entCache[key]
end

local function zoneName(map)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    return info and info.name or ("map " .. tostring(map))
end
R.ZoneName = zoneName

local function myWorld()
    if not UnitPosition then return nil end
    local a, b, _, inst = UnitPosition("player")
    if type(a) ~= "number" or isSecret(a) or isSecret(b) then return nil end
    return a, b, inst
end

-- the nearest entrance for a position: entrance, yards (nil when on another continent)
local function nearestEntrance(key, a, b, inst)
    local list = entrancesOf(key)
    if not list or not (OMQ.Guide and OMQ.Guide.WorldOf) then return nil end
    local best, bd, any
    for _, e in ipairs(list) do
        local w = OMQ.Guide.WorldOf(e)
        if w then
            any = any or e
            if a and w[3] == inst then
                local d = math.sqrt((w[1] - a) ^ 2 + (w[2] - b) ^ 2)
                if not bd or d < bd then best, bd = e, d end
            end
        end
    end
    return best or any, bd
end
R.NearestEntrance = nearestEntrance

-- distance of a row (me or a dad) to the entrance, as text
function R:EntranceText(r)
    local key = self.dungeon
    if not key or not entrancesOf(key) then return "-", GREY end
    local a, b, inst
    if r.isSelf then a, b, inst = myWorld()
    else
        local u = r.guid and OMQ.users[r.guid]
        local p = u and u.pos
        if p and (GetTime() - (p.at or 0)) < 30 then a, b, inst = p.a, p.b, p.inst end
    end
    if not a then return "-", GREY end
    local _, d = nearestEntrance(key, a, b, inst)
    if not d then return "other continent", GREY end
    return string.format("%d yd", math.floor(d + 0.5)), (d < 150) and GREEN or { 0.85, 0.85, 0.88 }
end

function R:GuideToEntrance()
    local key = self.dungeon
    local d = key and OMQ:DungeonByKey(key)
    if not d then return end
    local a, b, inst = myWorld()
    local e, dist = nearestEntrance(key, a, b, inst)
    if not e then OMQ:Print(d.name .. ": the entrance is not known yet"); return end
    if not dist then OMQ:Print(d.name .. ": the entrance is on another continent (" .. zoneName(e.map) .. ")"); return end
    local w = OMQ.Guide.WorldOf(e)
    OMQ.Guide:StartAt(d.name, w[1], w[2], w[3])         -- only for me: nothing is sent (decision 193)
    frame:Hide()                                         -- so the arrow can be seen (decision 195)
end

function R:EntranceTip(owner)
    if not GameTooltip then return end
    local key = self.dungeon
    if not key then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText("Dungeon entrance")
    local note = OMQ.DungeonEntranceNotes and OMQ.DungeonEntranceNotes[key]    -- how to get in (decision 254)
    if note then GameTooltip:AddLine(note, 0.93, 0.92, 0.89, true) end
    GameTooltip:AddLine("Click: arrow to the entrance (only for you)", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

-- where a dungeon quest starts: info table or nil
function R.QuestStart(q)
    local S = OMQ.QuestStarts or {}
    local st = S[q.id]
    if not st then
        for _, alt in ipairs(q.alt or {}) do if S[alt] then st = S[alt]; break end end
    end
    if not st then return nil end
    local giver = st[3]
    if GetLocale and GetLocale() == "deDE" and st[4] then giver = st[4] end
    return { root = st[1], rootName = st[2], giver = giver, map = st[5], x = st[6], y = st[7], kind = st[8],
             chain = st[1] ~= q.id }
end

-- the id of the quest as it is in my log (any of its ids), or nil
local function myLogId(q)
    local CQ = C_QuestLog
    if not (CQ and CQ.GetLogIndexForQuestID) then return nil end
    local ids = { q.id }
    for _, a in ipairs(q.alt or {}) do ids[#ids + 1] = a end
    for _, id in ipairs(ids) do
        local ok, idx = pcall(CQ.GetLogIndexForQuestID, id)
        if ok and idx then return id, idx end
    end
end

-- the quest log opens on this quest (several ways, whatever the client has)
function R.OpenQuestLog(qid, idx)
    if C_QuestLog and C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, qid) end
    if QuestMapFrame_OpenToQuestDetails then
        if pcall(QuestMapFrame_OpenToQuestDetails, qid) then return true end
    end
    if QuestLog_OpenToQuest and idx then
        if pcall(QuestLog_OpenToQuest, idx) then return true end
    end
    if QuestLogFrame and ShowUIPanel then
        pcall(ShowUIPanel, QuestLogFrame)
        if QuestLog_SetSelection and idx then pcall(QuestLog_SetSelection, idx) end
        if QuestLog_Update then pcall(QuestLog_Update) end
        return true
    end
    if ToggleQuestLog then pcall(ToggleQuestLog); return true end
    return false
end

-- a click on a quest row: in my log -> the quest log; else -> an arrow to the (first) quest giver
function R:QuestClick(q)
    local qid, idx = myLogId(q)
    if qid then
        frame:Hide()
        R.OpenQuestLog(qid, idx)
        return "log"
    end
    local st = R.QuestStart(q)
    if st and st.kind == "inside" then
        OMQ:Print((q.name or "Quest") .. ": starts inside the dungeon (" .. (st.giver or "?") .. ")")
        return "none"
    end
    if not st or st.kind == "item" or not st.map or st.map == 0 then
        OMQ:Print((q.name or "Quest") .. ": " .. (st and "starts from an item - no quest giver to walk to" or "the quest giver is not known yet"))
        return "none"
    end
    local w = OMQ.Guide and OMQ.Guide.WorldOf({ nil, nil, st.map, st.x, st.y })
    local a, b, inst = myWorld()
    if not w then OMQ:Print("no position for " .. (st.giver or "the quest giver")); return "none" end
    if a and w[3] ~= inst then
        OMQ:Print((st.giver or "The quest giver") .. " is on another continent (" .. zoneName(st.map) .. ")")
        return "continent"
    end
    OMQ.Guide:StartAt(st.giver ~= "" and st.giver or (q.name or "Quest giver"), w[1], w[2], w[3])   -- only for me
    frame:Hide()                                         -- so the arrow can be seen (decision 195)
    if st.chain then OMQ:Print(string.format("%s starts with \"%s\" - arrow to %s", q.name or "The quest", st.rootName, st.giver)) end
    return "arrow"
end

function R:Render()
    if not frame or not frame:IsShown() then return end
    local rows = self:Rows()
    local d = self.dungeon and OMQ:DungeonByKey(self.dungeon)
    -- with a dungeon: the entrance line under the title, and a column for the distance
    local top = PAD + 22
    if d then
        local list = entrancesOf(d.key)
        entrance:ClearAllPoints()
        entrance:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(PAD + 20))
        if list then
            local a, b, inst = myWorld()
            local e, dist = nearestEntrance(d.key, a, b, inst)
            e = e or list[1]                         -- no world position known: the first entrance
            local zone = zoneName(e.map)
            entrance.text:SetText("Entrance: " .. zone .. (dist and string.format("  |cff9aa0aa(%d yd - click for the arrow)|r", math.floor(dist + 0.5)) or "  |cff9aa0aa(other continent)|r"))
            entrance.text:SetTextColor(0.89, 0.71, 0.29)
        else
            entrance.text:SetText("Entrance: not known yet")
            entrance.text:SetTextColor(GREY[1], GREY[2], GREY[3])
        end
        entrance:SetWidth(math.max(120, (entrance.text:GetStringWidth() or 200) + 4))
        entrance:Show()
        top = PAD + 46
    else
        entrance:Hide()
    end
    local ncol = d and 6 or 5
    local xs = { 0, NAME_W, NAME_W + COL_W, NAME_W + COL_W * 2, NAME_W + COL_W * 3, NAME_W + COL_W * 3 + XCOL_W }
    for r = 0, 5 do
        for c = 1, 6 do
            local fs = cells[r][c]
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + xs[c], -(top + r * ROW_H))
            if c == 6 and not d then fs:SetText("") elseif c == 6 and r == 0 then fs:SetText("To entrance") end
        end
    end
    for i = 1, 5 do
        local c, r = cells[i], rows[i]
        if not r then
            for k = 1, 6 do c[k]:SetText("") end
        else
            c[1]:SetText(r.name or "?")
            c[1]:SetTextColor(classColor(r.class))
            local row = r.row
            if not row then
                setCell(c[2], r.state == "wait" and "..." or "no answer", GREY)
                for k = 3, 5 do c[k]:SetText("") end
            else
                setCell(c[2], row.dur and (row.dur .. "%") or "-", (row.dur and row.dur < LIMIT.dur) and RED or GREEN)
                setCell(c[3], row.free and tostring(row.free) or "-", (row.free and row.free < LIMIT.free) and RED or GREEN)
                if row.drink then
                    setCell(c[4], tostring(row.drink), row.drink < LIMIT.drink and RED or GREEN)
                else
                    setCell(c[4], "-", GREY)
                end
                if row.xkey and row.xcount then
                    setCell(c[5], row.xcount .. " " .. XLABEL[row.xkey], row.xcount < LIMIT[row.xkey] and RED or GREEN)
                else
                    setCell(c[5], "-", GREY)
                end
            end
            if d then
                local t, col = self:EntranceText(r)
                setCell(c[6], t, col)
            else
                c[6]:SetText("")
            end
        end
    end
    local n = math.max(1, math.min(#rows, 5))
    local y = top + (n + 1) * ROW_H + 4
    footer:ClearAllPoints()
    footer:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
    local problems = self:Verdict(rows)
    if #problems == 0 then
        footer:SetText("Everybody is ready")
        footer:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
    else
        footer:SetText(table.concat(problems, "\n"))
        footer:SetTextColor(RED[1], RED[2], RED[3])
    end
    local lines = math.max(1, #problems)
    local width = PAD * 2 + NAME_W + COL_W * 3 + XCOL_W + (d and ENT_W or 0)
    local height = y + lines * 14 + PAD
    local quests = d and OMQ:DungeonQuests(d, UnitFactionGroup and UnitFactionGroup("player")) or {}
    title:SetText(d and ("Group Check: " .. d.name) or "Group Check")
    local arrows = d and #R.Relevant() > 1
    prevBtn:SetShown(arrows and true or false)
    nextBtn:SetShown(arrows and true or false)
    title:ClearAllPoints()
    title:SetPoint("TOPLEFT", arrows and (PAD + 20) or PAD, -PAD)
    local nm = math.max(1, math.min(#rows, 5))
    for i = 1, #qcells do for k = 1, 7 do qcells[i][k]:SetText("") end end
    for _, btn in ipairs(qbuttons) do btn:Hide() end
    qhead.name:SetText("")
    for c = 1, 5 do qhead.cols[c]:SetText("") end
    if d then
        local qy = height + 10
        width = math.max(width, PAD * 2 + QNAME_W + nm * QCOL_W)
        qhead.name:ClearAllPoints()
        qhead.name:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -qy)
        qhead.name:SetText(#quests > 0 and "Dungeon quests  |cff9aa0aa(click: your quest log, or an arrow to the quest giver)|r" or "No dungeon quests known")
        for c = 1, nm do
            local r = rows[c]
            qhead.cols[c]:ClearAllPoints()
            qhead.cols[c]:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + QNAME_W + (c - 1) * QCOL_W, -(qy + 16))
            qhead.cols[c]:SetText(#quests > 0 and (r.name or "?") or "")
            qhead.cols[c]:SetTextColor(classColor(r.class))
        end
        for i, q in ipairs(quests) do
            if not qcells[i] then
                qcells[i] = {}
                for k = 1, 7 do
                    local fs = frame:CreateFontString(nil, "OVERLAY", (k == 1) and "GameFontHighlight" or (k == 7 and "GameFontDisableSmall" or "GameFontHighlightSmall"))
                    fs:SetJustifyH("LEFT")
                    if fs.SetWordWrap then fs:SetWordWrap(false) end
                    fs:SetWidth((k == 1 or k == 7) and QNAME_W - 8 or QCOL_W - 4)
                    qcells[i][k] = fs
                end
                local btn = CreateFrame("Button", nil, frame)
                btn.bg = btn:CreateTexture(nil, "BACKGROUND")
                btn.bg:SetAllPoints()
                btn.bg:SetColorTexture(1, 1, 1, 0.03)
                btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                btn:SetScript("OnClick", function(self) if self.quest then R:QuestClick(self.quest) end end)
                btn:SetScript("OnEnter", function(self)
                    if not (GameTooltip and self.quest) then return end
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(self.title or self.quest.name)
                    if myLogId(self.quest) then
                        GameTooltip:AddLine("Click: open it in your quest log", 0.8, 0.8, 0.8)
                    else
                        local st = R.QuestStart(self.quest)
                        if st and st.kind ~= "item" and st.map and st.map ~= 0 then
                            GameTooltip:AddLine("Click: arrow to " .. st.giver .. " (" .. zoneName(st.map) .. "), only for you", 0.8, 0.8, 0.8)
                            if st.chain then GameTooltip:AddLine("The chain starts with \"" .. st.rootName .. "\"", 0.89, 0.71, 0.29) end
                        elseif st and st.kind == "inside" then
                            GameTooltip:AddLine("Starts inside the dungeon: " .. st.giver, 0.6, 0.63, 0.68)
                        elseif st then
                            GameTooltip:AddLine("Starts from an item", 0.6, 0.63, 0.68)
                        else
                            GameTooltip:AddLine("Quest giver not known yet", 0.6, 0.63, 0.68)
                        end
                    end
                    -- the item rewards with their item score (decision 279)
                    if OMQ.LootPreview and OMQ.LootPreview.AddRewardLines then OMQ.LootPreview:AddRewardLines(GameTooltip, self.quest, self) end
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
                qbuttons[i] = btn
            end
            local yy = qy + 34 + (i - 1) * QROW_H
            local title_ = q.name
            if C_QuestLog and C_QuestLog.GetTitleForQuestID then
                local ok, t = pcall(C_QuestLog.GetTitleForQuestID, q.id)
                if ok and type(t) == "string" and t ~= "" and not isSecret(t) then title_ = t end
            end
            local btn = qbuttons[i]
            btn.quest, btn.title = q, title_
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD - 4, -(yy - 3))
            btn:SetSize(QNAME_W - 2, QROW_H - 2)           -- only the quest, not the dads' columns (decision 195)
            btn:Show()
            qcells[i][1]:ClearAllPoints()
            qcells[i][1]:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -yy)
            qcells[i][1]:SetText(title_ .. "  |cff9aa0aa" .. (q.level or "?") .. "|r")
            qcells[i][1]:SetTextColor(0.93, 0.92, 0.89)
            -- where it starts, in grey under the name
            local st = R.QuestStart(q)
            local sub
            if myLogId(q) then sub = "In your quest log"
            elseif st and st.kind ~= "item" and st.map and st.map ~= 0 then
                sub = (st.chain and ("Chain starts: " .. st.rootName .. " - ") or "Start: ") .. st.giver .. ", " .. zoneName(st.map)
            elseif st and st.kind == "inside" then sub = "Start: " .. st.giver .. ", inside the dungeon"
            elseif st then sub = "Starts from an item"
            else sub = "Quest giver not known yet" end
            qcells[i][7]:ClearAllPoints()
            qcells[i][7]:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(yy + 15))
            qcells[i][7]:SetText(sub)
            for c = 1, nm do
                local stt = self:QuestState(rows[c], q)
                local fs = qcells[i][c + 1]
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + QNAME_W + (c - 1) * QCOL_W, -(yy + 6))
                if stt then
                    fs:SetText(STATE_TEXT[stt][1])
                    fs:SetTextColor(STATE_TEXT[stt][2][1], STATE_TEXT[stt][2][2], STATE_TEXT[stt][2][3])
                else
                    fs:SetText(rows[c].state == "wait" and "..." or "?")
                    fs:SetTextColor(GREY[1], GREY[2], GREY[3])
                end
            end
        end
        height = qy + 34 + #quests * QROW_H + PAD
        -- the best boss loot for me (decision 233)
        if OMQ.LootPreview then
            width = math.max(width, OMQ.LootPreview.MIN_W)
            local ly = height - PAD + 12
            local lh = OMQ.LootPreview:Render(frame, d.key, PAD, ly, width - PAD * 2)
            height = ly + lh + PAD
        end
    elseif OMQ.LootPreview then
        OMQ.LootPreview:Hide()
    end
    footer:SetWidth(width - PAD * 2)
    frame:SetSize(width, height)
end
function R:Frame() return frame end
R._QuestButtons = function() return qbuttons end

function R:Open(dungeonKey)
    if not frame then build() end
    self.dungeon = (type(dungeonKey) == "string" and OMQ:DungeonByKey(dungeonKey)) and dungeonKey or nil
    if self.dungeon and OMQ.Unlock and not OMQ.Unlock:Has("dungeon") then self.dungeon = nil end   -- dungeon checks from level 13
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:Show()
    self:Ask()
    self:Render()
end

-- the same button closes the window, another one switches it
function R:Toggle(dungeonKey)
    local key = type(dungeonKey) == "string" and dungeonKey or nil
    if key and OMQ.Unlock and not OMQ.Unlock:Has("dungeon") then key = nil end
    if frame and frame:IsShown() and self.dungeon == key then frame:Hide() else self:Open(key) end
end

OMQ:On("USER_UPDATED", function() if frame and frame:IsShown() then R:Render() end end)

OMQ:RegisterCommand("ready", function(arg)
    local key = arg and arg:match("^%s*(%S+)")
    if key and not OMQ:DungeonByKey(key) then
        local keys = {}
        for _, d in ipairs(OMQ.Dungeons) do keys[#keys + 1] = d.key end
        OMQ:Print("Unknown dungeon. Keys: " .. table.concat(keys, ", "))
        return
    end
    R:Toggle(key)
end, "Group Check [dungeon key]: durability, bags, drinks, class items and dungeon quests of the group")

----------------------------------------------------------------------
-- /omq dungeons: what the game says about dungeon level ranges (read only, decision 143)
----------------------------------------------------------------------
OMQ:RegisterCommand("dungeons", function()
    local out = { "One More Quest: dungeon list of the game (GetLFGDungeonInfo), compared with Data/DungeonQuests.lua" }
    local function clean(v)
        local t = tostring(v):gsub("[%c|]", " ")
        return t
    end
    if not GetLFGDungeonInfo then
        out[#out + 1] = "GetLFGDungeonInfo does not exist on this client"
    else
        local found = 0
        for id = 1, 3000 do
            local ok, name, typeID, subtype, minL, maxL, recL, minRec, maxRec = pcall(GetLFGDungeonInfo, id)
            if ok and type(name) == "string" and name ~= "" and (typeID == 1 or typeID == nil or typeID == 2) then
                found = found + 1
                out[#out + 1] = string.format("id %d | %s | type %s sub %s | level %s-%s | rec %s (%s-%s)", id, clean(name),
                    clean(typeID), clean(subtype), clean(minL), clean(maxL), clean(recL), clean(minRec), clean(maxRec))
            end
        end
        out[#out + 1] = "entries: " .. found
    end
    out[#out + 1] = "-- addon database"
    for _, d in ipairs(OMQ.Dungeons) do
        out[#out + 1] = string.format("%s | %s | %d-%d | %d quests", d.key, d.name, d.min, d.max, #d.quests)
    end
    out[#out + 1] = "-- end. Please send this whole report (Ctrl+A, Ctrl+C in the window)."
    OMQ.debugReport = true
    local ok, e = pcall(OMQ.ShowReport, OMQ, out)
    OMQ.debugReport = nil
    if not ok then for _, l in ipairs(out) do print(l) end end
end, "report: dungeon names and level ranges as the game lists them")
