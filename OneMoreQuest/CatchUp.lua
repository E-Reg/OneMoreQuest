-- One More Quest: Catch Up - the dad who fell behind
-- One question, answered in one window: can I join the dads now? Can I take the quests they are on,
-- and walk where they walk - or is something missing?
--   For every quest the dads have and I do not, the requirements are checked against my character:
--   my level, the quest's required level, faction, race, class, the pre-quests of its chain, a branch
--   I have already taken, quests that start from an item and quests I have handed in long ago. What is
--   missing is named, with the level I need for it.
--   Two more things decide whether playing together works: automatic quest sharing only runs between
--   dads at most 5 levels apart (QuestSync.LEVEL_GAP), and the zone the dads are in has a level range
--   of its own (Data/QuestZones.lua).
-- Nothing new goes over the wire: the quest lists are the ones quest sync already exchanges (message
-- "Q"), the levels come from the party units or the gear message, the zones from the client.
-- The last picture of the group is kept per character in OMQDB.catchup, so the check also answers
-- "is it time yet?" while I level alone, hours after the dads logged off.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local C = {}
OMQ.CatchUp = C

C.SAVE_EVERY = 45           -- seconds between two saved pictures of the group
C.MAX_SAVED = 60            -- quests kept per dad in the saved picture
C.MAX_ROWS = 14             -- quests listed in the window (the rest is counted)
C.HARD_ABOVE = 4            -- a quest this many levels above mine is named as tough
C.JOIN_DELAY = 12           -- seconds after a dad joined until the summary line (the sync round first)

local function isSecret(v) return issecretvalue and issecretvalue(v) end
local function num(v)
    if type(v) ~= "number" or isSecret(v) then return nil end
    return v
end
local function data(id) return OMQ.QuestPlaces and OMQ.QuestPlaces[id] end
local function has(flags, b) return flags ~= nil and math.floor(flags / b) % 2 == 1 end
local function gap() return (OMQ.QuestSync and OMQ.QuestSync.LEVEL_GAP) or 5 end

local function everDone(id)
    local CQ = C_QuestLog
    if CQ and CQ.IsQuestFlaggedCompleted then
        local ok, r = pcall(CQ.IsQuestFlaggedCompleted, id)
        if ok then return r and true or false end
    end
    if IsQuestFlaggedCompleted then
        local ok, r = pcall(IsQuestFlaggedCompleted, id)
        if ok then return r and true or false end
    end
    return false
end

-- the quest name as this client shows it, else the English name from the quest data
local function titleOf(id)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, t = pcall(C_QuestLog.GetTitleForQuestID, id)
        if ok and type(t) == "string" and t ~= "" and not isSecret(t) then return t end
    end
    local d = data(id)
    if d and type(d[1]) == "string" and d[1] ~= "" then return d[1] end
    return "quest " .. tostring(id)
end
C.TitleOf = titleOf

local function zoneName(map)
    if not map or map == 0 then return nil end
    if C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, map)
        if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" and not isSecret(info.name) then
            return info.name
        end
    end
    for _, z in ipairs(OMQ.QuestZones or {}) do if z[1] == map then return z[5] end end
    return nil
end
C.ZoneName = zoneName

-- the level range of a zone (Data/QuestZones.lua)
local function zoneBand(map)
    for _, z in ipairs(OMQ.QuestZones or {}) do
        if z[1] == map then return z[2], z[3] end
    end
    return nil
end

----------------------------------------------------------------------
-- Names for the requirement texts: from the game, in the client's language
----------------------------------------------------------------------
local RACE_NAME = { "Human", "Orc", "Dwarf", "Night Elf", "Undead", "Tauren", "Gnome", "Troll", "Goblin",
                    "Blood Elf", "Draenei" }
local CLASS_NAME = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Death Knight", "Shaman", "Mage",
                     "Warlock", "Monk", "Druid" }

local function raceName(id)
    if C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
        local ok, info = pcall(C_CreatureInfo.GetRaceInfo, id)
        if ok and type(info) == "table" and type(info.raceName) == "string" and info.raceName ~= "" then
            return info.raceName
        end
    end
    return RACE_NAME[id] or ("race " .. tostring(id))
end

local function className(id)
    if GetClassInfo then
        local ok, n = pcall(GetClassInfo, id)
        if ok and type(n) == "string" and n ~= "" and not isSecret(n) then return n end
    end
    return CLASS_NAME[id] or ("class " .. tostring(id))
end

local function nameList(ids, fn, max)
    local out = {}
    for i, id in ipairs(ids or {}) do
        if max and i > max then out[#out + 1] = "..."; break end
        out[#out + 1] = fn(id)
    end
    return table.concat(out, ", ")
end

----------------------------------------------------------------------
-- Me
----------------------------------------------------------------------
local RACE_ID = { Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5, Undead = 5, Tauren = 6, Gnome = 7,
                  Troll = 8, Goblin = 9, BloodElf = 10, Draenei = 11 }

function C.Me()
    local level = UnitLevel and num(UnitLevel("player")) or nil
    local f = UnitFactionGroup and UnitFactionGroup("player")
    local raceFile, raceID, classID
    if UnitRace then raceFile, raceID = select(2, UnitRace("player")) end
    if UnitClass then classID = select(3, UnitClass("player")) end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if isSecret(map) then map = nil end
    local a, b, inst
    if UnitPosition then
        local y, x, _, i = UnitPosition("player")
        a, b, inst = num(y), num(x), num(i)
    end
    local me = OMQ:GetSelf()
    return { level = level or 1, name = me and me.name or "?", class = me and me.class or nil,
             fac = (f == "Alliance" and "A") or (f == "Horde" and "H") or nil,
             race = num(raceID) or RACE_ID[raceFile or ""], classID = num(classID),
             map = map, zone = zoneName(map), a = a, b = b, inst = inst }
end

----------------------------------------------------------------------
-- The group: live, or the last saved picture
----------------------------------------------------------------------
-- level of a dad: his party unit first, then what his gear message said
local function levelOfUser(guid)
    if OMQ.QuestSync and OMQ.QuestSync.LevelOf then
        local ok, l = pcall(OMQ.QuestSync.LevelOf, guid)
        if ok and num(l) and l > 0 then return l end
    end
    local u = OMQ.users and OMQ.users[guid]
    local l = u and num(tonumber(u.level))
    return (l and l > 0) and l or nil
end

local function unitOf(guid)
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists and UnitExists(unit) and UnitGUID and UnitGUID(unit) == guid then return unit end
    end
    return nil
end

local function unitWhere(unit)
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit(unit)
    if isSecret(map) then map = nil end
    local a, b, inst
    if UnitPosition then
        local y, x, _, i = UnitPosition(unit)
        a, b, inst = num(y), num(x), num(i)
    end
    return map, a, b, inst
end

-- the dads right now: everybody with the addon in my group, plus the group members without it
function C.Live()
    local out = {}
    local me = OMQ:GetSelf()
    local seen = {}
    for guid, u in pairs(OMQ.users or {}) do
        if (not me or guid ~= me.guid) and OMQ:IsOnline(u) then
            local unit = unitOf(guid)
            local map, a, b, inst
            if unit then map, a, b, inst = unitWhere(unit) end
            seen[guid] = true
            out[#out + 1] = { guid = guid, name = u.name or "?", class = u.class, level = levelOfUser(guid),
                              quests = u.quests, addon = true, live = true, map = map, a = a, b = b, inst = inst,
                              pos = OMQ:GroupPosition(guid) or 9 }
        end
    end
    -- group members without the addon: their level and zone are known, their quests are not
    if IsInGroup and IsInGroup() then
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists and UnitExists(unit) then
                local guid = UnitGUID and UnitGUID(unit)
                if guid and not isSecret(guid) and not seen[guid] and not (me and guid == me.guid) then
                    local map, a, b, inst = unitWhere(unit)
                    local _, class = UnitClass(unit)
                    local lvl = num(UnitLevel(unit))
                    out[#out + 1] = { guid = guid, name = (UnitName(unit)) or "?", class = class,
                                      level = (lvl and lvl > 0) and lvl or nil, quests = nil, addon = false,
                                      live = true, map = map, a = a, b = b, inst = inst, pos = i }
                end
            end
        end
    end
    table.sort(out, function(x, y)
        if (x.pos or 9) ~= (y.pos or 9) then return (x.pos or 9) < (y.pos or 9) end
        return (x.name or "") < (y.name or "")
    end)
    return out
end

----------------------------------------------------------------------
-- The saved picture (per character, OMQDB.catchup)
----------------------------------------------------------------------
local lastSave = -1000

local function store()
    OMQ.db.catchup = OMQ.db.catchup or {}
    return OMQ.db.catchup
end

function C:Save(force)
    if not OMQ.db then return false end
    local me = OMQ:GetSelf()
    if not me then return false end
    if not force and GetTime() - lastSave < C.SAVE_EVERY then return false end
    local live = C.Live()
    local any = false
    for _, m in ipairs(live) do if m.addon and m.quests then any = true end end
    if not any then return false end                     -- nothing worth remembering
    local members = {}
    for _, m in ipairs(live) do
        local ids
        if m.quests then
            ids = {}
            for id in pairs(m.quests) do ids[#ids + 1] = id end
            table.sort(ids)
            for i = #ids, C.MAX_SAVED + 1, -1 do ids[i] = nil end
        end
        members[#members + 1] = { guid = m.guid, name = m.name, class = m.class, level = m.level,
                                  map = m.map, addon = m.addon, quests = ids }
    end
    store()[me.guid] = { at = time(), members = members }
    lastSave = GetTime()
    return true
end

function C:Saved()
    local me = OMQ:GetSelf()
    local s = me and store()[me.guid]
    if not (s and type(s.members) == "table") then return nil end
    local out = {}
    for _, m in ipairs(s.members) do
        local set
        if type(m.quests) == "table" then
            set = {}
            for _, id in ipairs(m.quests) do set[id] = true end
        end
        out[#out + 1] = { guid = m.guid, name = m.name or "?", class = m.class, level = tonumber(m.level),
                          map = m.map, addon = m.addon ~= false, live = false, quests = set }
    end
    return out, tonumber(s.at)
end

function C:Forget()
    local me = OMQ:GetSelf()
    if me then store()[me.guid] = nil end
end

-- the dads to compare with: the group right now, else the last saved picture
function C:Party()
    local live = C.Live()
    local withQuests = 0
    for _, m in ipairs(live) do if m.quests then withQuests = withQuests + 1 end end
    if #live > 0 and withQuests > 0 then return live, "live", nil end
    local saved, at = self:Saved()
    if not saved or #saved == 0 then
        return live, #live > 0 and "live" or "none", nil
    end
    -- in a group whose lists have not arrived yet: the saved quests, but the levels and zones we see now.
    -- A saved picture of other dads says nothing about the group I am in: then the live one wins.
    if #live > 0 then
        local byGuid, out = {}, {}
        for _, m in ipairs(live) do byGuid[m.guid] = m end
        for _, s in ipairs(saved) do
            local l = byGuid[s.guid]
            if l then
                s.live = true
                s.map = l.map or s.map
                s.level = l.level or s.level
                s.a, s.b, s.inst = l.a, l.b, l.inst
                out[#out + 1] = s
            end
        end
        if #out == 0 then return live, "live", nil end
        for _, m in ipairs(live) do                       -- group members the saved picture does not know
            local known = false
            for _, s in ipairs(out) do if s.guid == m.guid then known = true; break end end
            if not known then out[#out + 1] = m end
        end
        return out, "saved", at
    end
    return saved, "saved", at
end

----------------------------------------------------------------------
-- The requirement check for one quest
----------------------------------------------------------------------
local function contains(list, v)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end

-- where the quest happens: its objectives, else the giver, else the turn-in
local function firstSpot(d)
    local spots = d and (d[9] or d[7] or d[8])
    return spots and spots[1] or nil
end

-- the place worth walking to: the quest giver, else the objectives
local function startSpot(d)
    local spots = d and (d[7] or d[9] or d[8])
    return spots and spots[1] or nil
end

-- What keeps me from this quest? A list of reasons, empty when nothing does.
-- kinds: level, faction, race, class, chain, branch, item, skill
function C.Blockers(id, me, log)
    local out = {}
    local d = data(id)
    if not d then return out, true end                   -- not in the quest data: nothing to check
    if (d[2] or 0) > (me.level or 1) then
        out[#out + 1] = { kind = "level", level = d[2], short = "Level " .. d[2],
                          text = string.format("needs level %d - you are %d", d[2], me.level or 1) }
    end
    if d[4] and me.fac and d[4] ~= me.fac then
        out[#out + 1] = { kind = "faction", short = "Other faction", text = "a quest of the other faction" }
    end
    if d[5] and me.race and not contains(d[5], me.race) then
        out[#out + 1] = { kind = "race", short = "Race", text = "only for " .. nameList(d[5], raceName, 3) }
    end
    if d[6] and me.classID and not contains(d[6], me.classID) then
        out[#out + 1] = { kind = "class", short = "Class quest", text = "only for " .. nameList(d[6], className, 3) }
    end
    -- the chain: every pre-quest of the group, or one of the single ones
    local missing = {}
    for _, p in ipairs(d[10] or {}) do if not everDone(p) then missing[#missing + 1] = p end end
    if #missing > 0 then
        local names = {}
        for i = 1, math.min(2, #missing) do names[i] = "\"" .. titleOf(missing[i]) .. "\"" end
        local more = #missing > 2 and string.format(" and %d more", #missing - 2) or ""
        out[#out + 1] = { kind = "chain", short = "Chain", quest = missing[1],
                          text = "needs " .. table.concat(names, ", ") .. more .. " first" }
    end
    if d[11] then
        local any, one = false, nil
        for _, p in ipairs(d[11]) do
            if everDone(p) then any = true; break end
            one = one or p
        end
        if not any then
            local names = {}
            for i = 1, math.min(2, #d[11]) do names[i] = "\"" .. titleOf(d[11][i]) .. "\"" end
            out[#out + 1] = { kind = "chain", short = "Chain", quest = one,
                              text = "needs one of " .. table.concat(names, ", ") .. " first" }
        end
    end
    for _, p in ipairs(d[12] or {}) do
        if everDone(p) or (log and log[p]) then
            out[#out + 1] = { kind = "branch", short = "Other branch",
                              text = "you are on another branch of this chain (\"" .. titleOf(p) .. "\")" }
            break
        end
    end
    if has(d[13], 2) then
        -- soft: the addon cannot read which skill or reputation the quest wants, so it never blocks one alone
        out[#out + 1] = { kind = "skill", soft = true, short = "Skill or rep",
                          text = "needs a profession skill or a reputation - whether you have it cannot be read from here" }
    end
    if has(d[13], 4) then
        out[#out + 1] = { kind = "item", short = "From an item",
                          text = "starts from an item - it cannot be shared, you need the item yourself" }
    end
    return out, false
end

-- Every quest the dads have and I do not, with what is missing for it.
function C:Quests(members, log, me)
    local holders, order = {}, {}
    for _, m in ipairs(members) do
        for id in pairs(m.quests or {}) do
            if not holders[id] then holders[id] = {}; order[#order + 1] = id end
            holders[id][#holders[id] + 1] = m.name or "?"
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        if not log[id] then
            local d = data(id)
            local e = { id = id, title = titleOf(id), who = holders[id], req = d and d[2] or nil,
                        qlevel = d and d[3] or nil, known = d ~= nil }
            local spot = firstSpot(d)
            e.zone = spot and zoneName(spot[1]) or nil
            e.spot = startSpot(d)
            e.dungeon = d and has(d[13], 8) or false
            if everDone(id) then
                e.state, e.short, e.why = "done", "Done", "you have handed this one in already"
            else
                local blockers, unknown = C.Blockers(id, me, log)
                local hard, soft = {}, {}
                for _, b in ipairs(blockers) do
                    if b.soft then soft[#soft + 1] = b else hard[#hard + 1] = b end
                end
                e.blockers, e.cautions = hard, soft
                if #hard == 0 then
                    e.state = "can"
                    e.short = #soft > 0 and "Can take?" or "Can take"
                    if #soft > 0 then e.why = soft[1].text
                    elseif unknown then e.why = "not in the quest data - nothing speaks against it"
                    else e.why = "nothing missing" end
                    if d and d[6] then e.pickup = true end       -- a class quest cannot be shared
                else
                    e.state = "blocked"
                    e.short = hard[1].short
                    local texts = {}
                    for _, b in ipairs(hard) do
                        texts[#texts + 1] = b.text
                        if b.kind == "level" then e.needLevel = b.level end
                        if b.kind == "chain" and b.quest then e.chainQuest = b.quest end
                    end
                    for _, b in ipairs(soft) do texts[#texts + 1] = b.text end
                    e.why = table.concat(texts, "; ")
                    -- only the level is missing: it opens by itself, no detour needed
                    e.onlyLevel = (#hard == 1 and hard[1].kind == "level") or nil
                end
                -- not blocking, but worth knowing: the quest is made for higher levels
                if e.qlevel and e.qlevel > (me.level or 1) + C.HARD_ABOVE then
                    e.note = string.format("quest level %d", e.qlevel)
                end
            end
            -- a chain: the arrow goes to the pre-quest that is missing, not to this quest
            if e.chainQuest then
                local cd = data(e.chainQuest)
                e.spot = startSpot(cd) or e.spot
                e.spotName = titleOf(e.chainQuest)
            end
            out[#out + 1] = e
        end
    end
    local RANK = { can = 1, blocked = 2, done = 3 }
    table.sort(out, function(x, y)
        local rx, ry = RANK[x.state] or 4, RANK[y.state] or 4
        if rx ~= ry then return rx < ry end
        if x.state == "blocked" then
            local lx, ly = x.needLevel or 99, y.needLevel or 99
            if lx ~= ly then return lx < ly end
        end
        local qx, qy = x.qlevel or 0, y.qlevel or 0
        if qx ~= qy then return qx < qy end
        return (x.title or "") < (y.title or "")
    end)
    return out
end

----------------------------------------------------------------------
-- Where the dads are, and how far away I am
----------------------------------------------------------------------
function C:Where(members, me)
    local w = {}
    local count, best = {}, nil
    for _, m in ipairs(members) do
        if m.map then
            count[m.map] = (count[m.map] or 0) + 1
            if not best or count[m.map] > count[best] then best = m.map end
        end
    end
    w.map = best
    w.zone = best and zoneName(best) or nil
    if best then w.low, w.high = zoneBand(best) end
    -- the nearest dad I could walk to
    local nearest
    for _, m in ipairs(members) do
        if m.live and m.a and m.b and me.a and me.b then
            if m.inst == me.inst then
                local d = math.sqrt((m.a - me.a) ^ 2 + (m.b - me.b) ^ 2)
                if not nearest or d < nearest.d then nearest = { d = d, m = m } end
            else
                w.otherContinent = true
            end
        end
    end
    if nearest then w.dist, w.who = nearest.d, nearest.m end
    return w
end

----------------------------------------------------------------------
-- The whole picture
----------------------------------------------------------------------
function C:Scan()
    local me = C.Me()
    local members, source, savedAt = self:Party()
    local log = {}
    if OMQ.QuestSync then
        local ok, ids = pcall(OMQ.QuestSync.ReadLog, OMQ.QuestSync)
        if ok and type(ids) == "table" then log = ids end
    end
    local rep = { me = me, members = members, source = source, savedAt = savedAt, log = log }
    rep.quests = self:Quests(members, log, me)
    rep.where = self:Where(members, me)

    -- levels of the group, and the level automatic sharing needs (QuestSync: at most 5 apart)
    local low, high, unknown, noAddon = nil, nil, {}, 0
    for _, m in ipairs(members) do
        if m.level then
            if not low or m.level < low then low = m.level end
            if not high or m.level > high then high = m.level end
        end
        if not m.addon then noAddon = noAddon + 1
        elseif not m.quests then unknown[#unknown + 1] = m.name or "?" end
    end
    local withLists = 0
    for _, m in ipairs(members) do if m.quests then withLists = withLists + 1 end end
    rep.withLists = withLists
    rep.low, rep.high, rep.unknown, rep.noAddon = low, high, unknown, noAddon
    rep.gap = (low and me.level) and (me.level - low) or nil
    rep.outOfRange = {}
    for _, m in ipairs(members) do
        if m.level and me.level and (m.level - me.level) > gap() then
            rep.outOfRange[#rep.outOfRange + 1] = { name = m.name, level = m.level }
        end
    end
    rep.shareLevel = (high and me.level and (high - gap()) > me.level) and (high - gap()) or nil

    -- counts, and the levels that open something
    local n = { can = 0, level = 0, hard = 0, done = 0, mine = 0 }
    local nextLevel, allLevel = nil, nil
    rep.openAt = {}                                      -- level -> how many quests open there
    for _, e in ipairs(rep.quests) do
        if e.state == "can" then n.can = n.can + 1
        elseif e.state == "done" then n.done = n.done + 1
        elseif e.onlyLevel and e.needLevel then
            n.level = n.level + 1
            rep.openAt[e.needLevel] = (rep.openAt[e.needLevel] or 0) + 1
            if not nextLevel or e.needLevel < nextLevel then nextLevel = e.needLevel end
            if not allLevel or e.needLevel > allLevel then allLevel = e.needLevel end
        else
            n.hard = n.hard + 1
        end
    end
    -- quests of mine the dads lack: what I bring to the group
    for id in pairs(log) do
        for _, m in ipairs(members) do
            if m.quests and not m.quests[id] then n.mine = n.mine + 1; break end
        end
    end
    n.total = 0
    for _, e in ipairs(rep.quests) do if e.state ~= "done" then n.total = n.total + 1 end end
    rep.counts, rep.nextLevel, rep.allLevel = n, nextLevel, allLevel

    -- the zone the dads are in: is it made for my level?
    local w = rep.where
    if w.low and me.level and me.level < w.low then
        rep.zoneShort = string.format("%s is for level %d-%d", w.zone or "their zone", w.low, w.high or w.low)
    end

    rep.verdict = self:Verdict(rep)
    return rep
end

-- "none", "ready", "soon" or "behind", with the sentence that belongs to it
function C:Verdict(rep)
    local n = rep.counts
    if rep.source == "none" or #rep.members == 0 then
        return { state = "none", text = "No dads known yet - group up once, then this check works any time" }
    end
    if (rep.withLists or 0) == 0 then
        return { state = "soon", text = "No quest list from the dads yet - nothing to compare" }
    end
    if n.total == 0 then
        if n.done > 0 then
            return { state = "ready", text = string.format(
                "Ready to join - and you are ahead: %d of their quests you have handed in already", n.done) }
        end
        return { state = "ready", text = "You have every quest the dads have - go and play" }
    end
    local hold = {}
    if n.level > 0 and rep.nextLevel then
        hold[#hold + 1] = string.format("level %d for %d of their quests", rep.nextLevel,
            rep.openAt[rep.nextLevel] or n.level)
    end
    if rep.shareLevel then
        hold[#hold + 1] = string.format("level %d so their shares reach you automatically", rep.shareLevel)
    end
    if n.can == 0 then
        if #hold == 0 then
            return { state = "behind", text = string.format("Not yet - none of their %d quests is open for you", n.total) }
        end
        return { state = "behind", text = "Not yet - you need " .. table.concat(hold, " and ") }
    end
    if #hold > 0 or rep.zoneShort then
        local parts = { string.format("%d of %d of their quests are open for you now", n.can, n.total) }
        if #hold > 0 then parts[#parts + 1] = "you still need " .. table.concat(hold, ", ") end
        if rep.zoneShort then parts[#parts + 1] = rep.zoneShort end
        return { state = "soon", text = "Almost - " .. table.concat(parts, "; ") }
    end
    return { state = "ready", text = string.format("Ready to join - you can take all %d quest%s the dads are on",
             n.can, n.can == 1 and "" or "s") }
end

----------------------------------------------------------------------
-- Lines, for the chat and the copyable report
----------------------------------------------------------------------
local function ago(seconds)
    if not seconds then return "a while ago" end
    if seconds < 90 then return string.format("%d seconds ago", math.max(1, math.floor(seconds))) end
    if seconds < 5400 then return string.format("%d minutes ago", math.floor(seconds / 60 + 0.5)) end
    if seconds < 86400 then return string.format("%d hours ago", math.floor(seconds / 3600 + 0.5)) end
    return string.format("%d days ago", math.floor(seconds / 86400 + 0.5))
end
C.Ago = ago

function C:Lines(rep)
    rep = rep or self:Scan()
    local out = { "One More Quest: Catch Up" }
    local me = rep.me
    out[#out + 1] = string.format("you: %s, level %d%s", me.name or "?", me.level or 1,
        me.zone and (", " .. me.zone) or "")
    if rep.source == "saved" then
        out[#out + 1] = "the dads: last picture from " .. ago(rep.savedAt and (time() - rep.savedAt) or nil)
    elseif rep.source == "live" then
        out[#out + 1] = "the dads: in your group now"
    end
    for _, m in ipairs(rep.members) do
        out[#out + 1] = string.format("  %s%s%s%s", m.name or "?",
            m.level and (", level " .. m.level) or "",
            m.map and (", " .. (zoneName(m.map) or "?")) or "",
            m.addon and "" or " (no addon - quests unknown)")
    end
    local w = rep.where
    if w.zone then
        out[#out + 1] = string.format("their zone: %s%s%s", w.zone,
            (w.low and string.format(" (level %d-%d)", w.low, w.high or w.low)) or "",
            w.dist and string.format(", %d yards from you", math.floor(w.dist + 0.5))
                or (w.otherContinent and ", another continent" or ""))
    end
    out[#out + 1] = rep.verdict.text
    local n = rep.counts
    out[#out + 1] = string.format("their quests you lack: %d - %d you can take, %d only need a level, %d need more",
        n.total, n.can, n.level, n.hard)
    if rep.allLevel and rep.allLevel ~= rep.nextLevel then
        out[#out + 1] = string.format("every quest that only waits for a level is open at level %d", rep.allLevel)
    end
    if n.done > 0 then out[#out + 1] = string.format("%d of their quests you have handed in already", n.done) end
    if n.mine > 0 then out[#out + 1] = string.format("%d quests of yours the dads lack - you can share those to them", n.mine) end
    for _, o in ipairs(rep.outOfRange) do
        out[#out + 1] = string.format("%s is level %d, more than %d above you: his quests are not accepted automatically (the share window still asks)",
            o.name or "?", o.level, gap())
    end
    if #rep.unknown > 0 then out[#out + 1] = "no quest list yet from: " .. table.concat(rep.unknown, ", ") end
    if rep.noAddon > 0 then
        out[#out + 1] = string.format("%d group member%s without the addon: their quests cannot be read",
            rep.noAddon, rep.noAddon == 1 and "" or "s")
    end
    out[#out + 1] = "quests:"
    for _, e in ipairs(rep.quests) do
        out[#out + 1] = string.format("  [%s] %s%s - %s%s%s", e.short or "?", e.title or "?",
            e.zone and (" (" .. e.zone .. ")") or "", e.why or "",
            e.note and (" [" .. e.note .. "]") or "",
            e.who and (" - has it: " .. table.concat(e.who, ", ")) or "")
    end
    return out
end

-- one line for the chat
function C:Summary(rep)
    rep = rep or self:Scan()
    return rep.verdict.text
end

----------------------------------------------------------------------
-- The nudge: a line in the chat when a level opens their quests
----------------------------------------------------------------------
function C:NudgeOn()
    if not OMQ:Master("group") then return false end
    return OMQ.db and OMQ.db.options and OMQ.db.options.catchupNudge ~= false
end

-- what this level opened: the quests that needed exactly it, and the sharing limit
function C:Opened(level, rep)
    rep = rep or self:Scan()
    local opened = 0
    for _, e in ipairs(rep.quests) do
        if e.onlyLevel and e.needLevel == level then opened = opened + 1 end
    end
    local share = (rep.high and (rep.high - gap()) == level) and true or false
    return opened, share, rep
end

local function nudgeLevel(level)
    if not C:NudgeOn() then return end
    local opened, share, rep = C:Opened(level)
    if opened == 0 and not share then return end
    local parts = {}
    if opened > 0 then
        parts[#parts + 1] = string.format("%d more quest%s of the dads %s open for you",
            opened, opened == 1 and "" or "s", opened == 1 and "is" or "are")
    end
    if share then
        parts[#parts + 1] = string.format("you are within %d levels of them again - their quests are accepted automatically", gap())
    end
    OMQ:Print(string.format("|cffe3b54aCatch Up|r - level %d: %s (/omq catchup)", level, table.concat(parts, ", ")))
    if OMQ.Sound then OMQ.Sound:Play("done") end
    local n = rep.counts
    if n.total > 0 and n.can + opened >= n.total then
        OMQ:Print("|cffe3b54aCatch Up|r - nothing is missing any more: time to join the dads")
    end
end
C._NudgeLevel = nudgeLevel

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
OMQ:On("DB_READY", function()
    OMQ.db.catchup = OMQ.db.catchup or {}
    if OMQ.db.options.catchupNudge == nil then OMQ.db.options.catchupNudge = true end
end)

OMQ:On("READY", function()
    C_Timer.NewTicker(C.SAVE_EVERY, function() pcall(C.Save, C) end)
end)

-- the quest lists of the dads changed: remember the picture (at most every SAVE_EVERY seconds)
OMQ:On("QUESTS_CHANGED", function() pcall(C.Save, C) end)
OMQ:On("USER_UPDATED", function() pcall(C.Save, C) end)

local joinAt
OMQ:On("USER_JOINED", function() joinAt = GetTime() + C.JOIN_DELAY end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LEVEL_UP", "PLAYER_LOGOUT", "GROUP_LEFT" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "PLAYER_LEVEL_UP" then
            local level = tonumber(arg1)
            -- UnitLevel lags behind the event: the check waits two seconds
            if level and C_Timer and C_Timer.After then C_Timer.After(2, function() pcall(nudgeLevel, level) end) end
        else
            C:Save(true)                                 -- the group breaks up or the game ends: keep what we know
        end
    end)
    if not ok then OMQ:Error("catchup " .. tostring(event), err) end
end)

-- the summary line a few seconds after a dad joined (the sync round has run by then)
ev:SetScript("OnUpdate", function()
    if not joinAt or GetTime() < joinAt then return end
    joinAt = nil
    if not C:NudgeOn() then return end
    local ok, rep = pcall(C.Scan, C)
    if not ok or type(rep) ~= "table" or rep.source ~= "live" then return end
    if rep.counts.total == 0 and rep.counts.done == 0 then return end
    OMQ:Print("|cffe3b54aCatch Up|r - " .. rep.verdict.text .. " (/omq catchup)")
end)

----------------------------------------------------------------------
-- /omq catchup
----------------------------------------------------------------------
OMQ:RegisterCommand("catchup", function(arg)
    arg = (arg or ""):match("^%s*(%S*)") or ""
    arg = arg:lower()
    if arg == "report" then
        local lines = C:Lines()
        if OMQ.ShowReport then OMQ:ShowReport(lines) else for _, l in ipairs(lines) do print(l) end end
        return
    elseif arg == "chat" or arg == "print" then
        for _, l in ipairs(C:Lines()) do print(l) end
        return
    elseif arg == "nudge" then
        OMQ.db.options.catchupNudge = not (OMQ.db.options.catchupNudge ~= false)
        OMQ:Fire("SETTINGS_CHANGED", "command")
        OMQ:Print("catch up lines in the chat " .. (OMQ.db.options.catchupNudge and "on" or "off"))
        return
    elseif arg == "forget" then
        C:Forget()
        OMQ:Print("the saved picture of the group is gone")
        return
    end
    if OMQ.CatchUpWindow then
        OMQ.CatchUpWindow:Toggle()
    else
        for _, l in ipairs(C:Lines()) do print(l) end
    end
end, "Catch Up: can you join the dads - their quests, what you are missing and the level you need (report | chat | nudge | forget)")
