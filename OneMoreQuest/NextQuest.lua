-- One More Quest: the "One more quest" search (decision 295)
-- Only behind the vote since decision 302: "One more quest!" wins the vote (/omq), the starter of the vote
-- looks for the quest and the arrow goes to everybody; alone, /omq looks at once.
-- One press, wherever I stand: the arrow leads to the place where the next quest can be done.
--   Candidates: solo every quest of my log, in a group only the quests every dad with the addon has
--   (QuestSync lists). Places come from Data/QuestPlaces.lua: the objective spots while a quest is not done
--   by everybody, the turn-in NPC once all are done. Quests whose objectives lie in a dungeon are left out.
--   Best = the lowest cost: distance in yards (my continent), plus ZONE_PENALTY when the spot is in another
--   zone, times BONUS for every other candidate quest within NEAR yards (several quests at once), turn-ins
--   win a tie. Another continent only when nothing is left on mine.
--   No common quest: a new one to pick up (stage 2): the nearest quest giver of a quest every dad can take
--   (level, faction, race, class, pre-quests done, not done yet).
-- In a group the presser asks the others once (message OQ) which of the quests are done for them and which
-- of the new ones they can take; after their answers (at most ASK_WAIT seconds) the target goes to every dad.
--   (quest IDs in base 36, separated by commas)
--   OQ|proto|a|reqid|guid|availIds            ask: the new quests I could take
--   OQ|proto|r|reqid|guid|doneIds|availIds    answer: my quests that are done, which of the new ones I can take
--   OQ|proto|g|guid|label|name|a|b|inst|radius the target for everybody
-- Pressing again within CYCLE seconds goes to the next best place of the same list.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local NQ = {}
OMQ.NextQuest = NQ

NQ.ZONE_PENALTY, NQ.NEAR, NQ.BONUS, NQ.BONUS_MAX = 300, 150, 0.7, 3
NQ.ASK_WAIT, NQ.AVAIL_ASK, NQ.CYCLE = 1.5, 15, 120
NQ.DONE_MAX = 20                   -- an addon message holds 255 characters: quest IDs go in base 36
NQ.OBJ_RADIUS, NQ.NPC_RADIUS = 40, 12
NQ.FAR = 1e6                       -- cost of a place on another continent

local function isSecret(v) return issecretvalue and issecretvalue(v) end
local function now() return GetTime() end
local function data(id) return OMQ.QuestPlaces and OMQ.QuestPlaces[id] end
local function has(flags, b) return flags ~= nil and math.floor(flags / b) % 2 == 1 end

----------------------------------------------------------------------
-- Positions
----------------------------------------------------------------------
local function xyOf(v)
    if type(v) ~= "table" then return nil end
    if v.GetXY then local ok, x, y = pcall(v.GetXY, v); if ok then return x, y end end
    return v.x, v.y
end
-- world position of a spot { map, x%, y% }: cached on the spot
local function world(spot)
    local w = rawget(spot, "w")
    if w == nil then
        w = false
        if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
            local ok, inst, vec = pcall(C_Map.GetWorldPosFromMapPos, spot[1], CreateVector2D(spot[2] / 100, spot[3] / 100))
            if ok then
                local a, b = xyOf(vec)
                if type(a) == "number" and type(b) == "number" then w = { a, b, inst } end
            end
        end
        spot.w = w
    end
    return w or nil
end
NQ.World = world
local function myPos()
    if not UnitPosition then return nil end
    local a, b, _, inst = UnitPosition("player")
    if type(a) ~= "number" or type(b) ~= "number" or isSecret(a) or isSecret(b) then return nil end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    return { a = a, b = b, inst = inst, map = map }
end
NQ.MyPos = myPos

----------------------------------------------------------------------
-- My quests
----------------------------------------------------------------------
local function myLog()
    if OMQ.QuestSync and OMQ.QuestSync.ReadLog then return OMQ.QuestSync:ReadLog() end
    return {}, {}
end
function NQ.IsComplete(id)
    local CQ = C_QuestLog
    if CQ and CQ.IsComplete then local ok, r = pcall(CQ.IsComplete, id); if ok and r then return true end end
    if CQ and CQ.ReadyForTurnIn then local ok, r = pcall(CQ.ReadyForTurnIn, id); if ok and r then return true end end
    return false
end
local function everDone(id)
    local CQ = C_QuestLog
    if CQ and CQ.IsQuestFlaggedCompleted then return CQ.IsQuestFlaggedCompleted(id) and true or false end
    if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(id) and true or false end
    return false
end
-- the first objective still open, in the words of the client
local function openObjective(id)
    local CQ = C_QuestLog
    if not (CQ and CQ.GetQuestObjectives) then return nil end
    local ok, list = pcall(CQ.GetQuestObjectives, id)
    if not ok or type(list) ~= "table" then return nil end
    for _, o in ipairs(list) do
        if type(o) == "table" and not o.finished and type(o.text) == "string" and o.text ~= "" and not isSecret(o.text) then return o.text end
    end
end
local function titleOf(id, titles)
    local t = titles and titles[id]
    if not t and C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, r = pcall(C_QuestLog.GetTitleForQuestID, id)
        if ok and type(r) == "string" and r ~= "" and not isSecret(r) then t = r end
    end
    local d = data(id)
    return t or (d and d[1]) or ("quest " .. id)
end

-- may I take this quest now? (stage 2)
local RACE_ID = { Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5, Undead = 5, Tauren = 6, Gnome = 7, Troll = 8, Goblin = 9,
                  BloodElf = 10, Draenei = 11 }
local function me()
    local level = UnitLevel and tonumber((UnitLevel("player"))) or 1
    local f = UnitFactionGroup and UnitFactionGroup("player")
    -- not "UnitRace and UnitRace()": "and" keeps only the first value (decision 305 found it)
    local raceFile, raceID, classID
    if UnitRace then raceFile, raceID = select(2, UnitRace("player")) end
    if UnitClass then classID = select(3, UnitClass("player")) end
    return { level = level, fac = (f == "Alliance" and "A") or (f == "Horde" and "H") or nil,
             race = raceID or RACE_ID[raceFile or ""], class = classID }
end
function NQ.GreyBelow(level)
    if GetQuestGreenRange then
        local ok, r = pcall(GetQuestGreenRange)
        if ok and type(r) == "number" then return level - r end
    end
    return level - 5 - math.floor(level / 10)
end
local function contains(list, v)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end
function NQ.CanTake(id, who, log)
    local d = data(id)
    if not d then return false end
    who = who or me()
    local flags = d[13]
    if has(flags, 1) or has(flags, 2) or has(flags, 4) or has(flags, 8) then return false end
    if not d[7] then return false end                                    -- no known quest giver
    if (log and log[id]) or everDone(id) then return false end
    if (d[2] or 0) > who.level then return false end
    local ql = d[3] or 0
    if ql > 0 and (ql > who.level + 3 or ql < NQ.GreyBelow(who.level)) then return false end
    if d[4] and who.fac and d[4] ~= who.fac then return false end
    if d[5] and who.race and not contains(d[5], who.race) then return false end
    if d[6] and who.class and not contains(d[6], who.class) then return false end
    for _, p in ipairs(d[10] or {}) do if not everDone(p) then return false end end
    if d[11] then
        local any = false
        for _, p in ipairs(d[11]) do if everDone(p) then any = true; break end end
        if not any then return false end
    end
    for _, p in ipairs(d[12] or {}) do if everDone(p) or (log and log[p]) then return false end end
    return true
end

-- could I accept this quest if somebody shares it? (decision 297, the sync round of QuestSync)
-- Not in my log, never done, required level, faction, race, class, pre-quests done, no excluding quest done.
-- A quest the data does not know only has to be not done yet.
function NQ.Acceptable(id, who, log)
    if (log and log[id]) or everDone(id) then return false end
    local d = data(id)
    if not d then return true end
    who = who or me()
    if (d[2] or 0) > who.level then return false end
    if d[4] and who.fac and d[4] ~= who.fac then return false end
    if d[5] and who.race and not contains(d[5], who.race) then return false end
    if d[6] and who.class and not contains(d[6], who.class) then return false end
    for _, p in ipairs(d[10] or {}) do if not everDone(p) then return false end end
    if d[11] then
        local any = false
        for _, p in ipairs(d[11]) do if everDone(p) then any = true; break end end
        if not any then return false end
    end
    for _, p in ipairs(d[12] or {}) do if everDone(p) or (log and log[p]) then return false end end
    return true
end

----------------------------------------------------------------------
-- Ranking
----------------------------------------------------------------------
-- cands: { id, kind = "obj"|"end"|"start", spots = { spot, ... } }; returns the best place per quest, best first
function NQ.Rank(cands, pos)
    local places = {}
    for _, c in ipairs(cands) do
        for _, s in ipairs(c.spots or {}) do
            local w = world(s)
            if w then
                local p = { id = c.id, kind = c.kind, spot = s, a = w[1], b = w[2], inst = w[3] }
                if pos and w[3] == pos.inst then
                    p.d = math.sqrt((w[1] - pos.a) ^ 2 + (w[2] - pos.b) ^ 2)
                    p.cost = p.d + ((pos.map and s[1] ~= pos.map) and NQ.ZONE_PENALTY or 0)
                else
                    p.cost = NQ.FAR
                end
                places[#places + 1] = p
            end
        end
    end
    -- several quests at one place
    for _, p in ipairs(places) do
        local seen, n = {}, 0
        for _, q in ipairs(places) do
            if q.id ~= p.id and not seen[q.id] and q.inst == p.inst
                and (q.a - p.a) ^ 2 + (q.b - p.b) ^ 2 <= NQ.NEAR * NQ.NEAR then
                seen[q.id] = true; n = n + 1
            end
        end
        p.others = n
        if p.cost < NQ.FAR then p.cost = p.cost * NQ.BONUS ^ math.min(n, NQ.BONUS_MAX) end
        if p.kind == "end" then p.cost = p.cost - 1 end
    end
    local best = {}
    for _, p in ipairs(places) do
        local b = best[p.id]
        if not b or p.cost < b.cost then best[p.id] = p end
    end
    local out = {}
    for _, p in pairs(best) do out[#out + 1] = p end
    table.sort(out, function(x, y) if x.cost ~= y.cost then return x.cost < y.cost end return x.id < y.id end)
    return out
end

----------------------------------------------------------------------
-- The group
----------------------------------------------------------------------
-- the dads with the addon in my group (not me), and how many members have no addon
function NQ.Members()
    local out, mine = {}, OMQ:GetSelf()
    for guid, u in pairs(OMQ.users or {}) do
        if (not mine or guid ~= mine.guid) and OMQ:IsOnline(u) then out[#out + 1] = u end
    end
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local without = math.max(0, n - 1 - #out)
    if n == 0 then without = 0 end
    return out, without
end

-- the quests of my log everybody has; unknown lists (no QuestSync yet) are named
function NQ.Common(log, members)
    local out, unknown = {}, {}
    for _, u in ipairs(members) do if not u.quests then unknown[#unknown + 1] = u.name or "?" end end
    for id in pairs(log) do
        local all = true
        for _, u in ipairs(members) do
            if u.quests and not u.quests[id] then all = false; break end
        end
        if all then out[#out + 1] = id end
    end
    table.sort(out)
    return out, unknown
end

-- log candidates: objectives while somebody still works on it, the turn-in once all are done
function NQ.LogCandidates(ids, doneBy)
    local out = {}
    for _, id in ipairs(ids) do
        local d = data(id)
        if d and not has(d[13], 8) then
            local done = NQ.IsComplete(id)
            for _, set in pairs(doneBy or {}) do if not set[id] then done = false end end
            local spots = (done or not d[9]) and d[8] or d[9]
            if spots then out[#out + 1] = { id = id, kind = (done or not d[9]) and "end" or "obj", spots = spots, done = done } end
        end
    end
    return out
end

-- stage 2: new quests I can take, nearest givers first (at most n)
function NQ.AvailableNear(pos, n, log)
    local who = me()
    local cands = {}
    for id, d in pairs(OMQ.QuestPlaces or {}) do
        if d[7] and NQ.CanTake(id, who, log) then cands[#cands + 1] = { id = id, kind = "start", spots = d[7] } end
    end
    local ranked = NQ.Rank(cands, pos)
    for i = #ranked, (n or NQ.AVAIL_ASK) + 1, -1 do ranked[i] = nil end
    return ranked
end

----------------------------------------------------------------------
-- The press
----------------------------------------------------------------------
local ask = nil          -- { reqid, at, members, replies = { guid = { done = set, avail = set } }, log, titles, pos, avail }
local last = nil         -- { list, idx, at }
NQ._state = function() return ask, last end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
    n = math.floor(n)
    if n == 0 then return "0" end
    local t = ""
    while n > 0 do local r = n % 36; t = DIGITS:sub(r + 1, r + 1) .. t; n = math.floor(n / 36) end
    return t
end
local function idsOf(list, max)
    local t = {}
    for i, x in ipairs(list) do
        if max and i > max then break end
        t[#t + 1] = b36(type(x) == "table" and x.id or x)
    end
    return table.concat(t, ",")
end
local function setOf(text)
    local s = {}
    for w in tostring(text or ""):gmatch("[%w]+") do local n = tonumber(w, 36); if n then s[n] = true end end
    return s
end
NQ._ids, NQ._set = idsOf, setOf

-- what the arrow says
function NQ.Describe(p, titles)
    local title = titleOf(p.id, titles)
    local what
    if p.kind == "end" then what = "turn in"
    elseif p.kind == "start" then what = "new quest - pick it up"
    else what = openObjective(p.id) or "objectives" end
    local more = (p.others or 0) > 0 and string.format(" (+%d more quest%s here)", p.others, p.others == 1 and "" or "s") or ""
    return title, what .. more
end

local function sendTarget(label, name, p, radius)
    local mine = OMQ:GetSelf()
    if not mine then return end
    OMQ:Send("OQ", "g", mine.guid, (label or ""):sub(1, 60), (name or ""):sub(1, 70),
        string.format("%.1f", p.a), string.format("%.1f", p.b), tostring(p.inst or 0), tostring(radius))
end

local function go(p, titles, share)
    local title, what = NQ.Describe(p, titles)
    local radius = p.kind == "obj" and NQ.OBJ_RADIUS or NQ.NPC_RADIUS
    local label = "One more quest: " .. title
    if OMQ.Guide then OMQ.Guide:StartAt(label, p.a, p.b, p.inst, "omq", nil, { name = what, radius = radius }) end
    if share then sendTarget(label, what, p, radius) end
    OMQ:Fire("NEXT_QUEST", p)
end

-- the decision once the answers are in (or solo at once)
function NQ.Decide(st)
    local members = st.members
    local doneBy, availBy = {}, {}
    for _, u in ipairs(members) do
        local r = st.replies[u.guid]
        if r then doneBy[u.guid] = r.done; availBy[u.guid] = r.avail end
    end
    local common = NQ.Common(st.log, members)
    local list = NQ.Rank(NQ.LogCandidates(common, doneBy), st.pos)
    local nearList = {}
    for _, p in ipairs(list) do if p.cost < NQ.FAR then nearList[#nearList + 1] = p end end
    if #nearList == 0 then
        -- stage 2: a new quest everybody can take
        local news = {}
        for _, p in ipairs(st.avail or {}) do
            local ok = true
            for _, u in ipairs(members) do
                local a = availBy[u.guid]
                if not (a and a[p.id]) then ok = false; break end
            end
            if ok and p.cost < NQ.FAR then news[#news + 1] = p end
        end
        if #news > 0 then nearList = news end
    end
    if #nearList == 0 then nearList = list end                         -- another continent at least
    last = { list = nearList, idx = 1, at = now(), titles = st.titles }
    if #nearList == 0 then
        OMQ:Print("one more quest: nothing found" .. (#members > 0 and " that every dad has or can take" or "") .. " - /omq next diag tells why")
        return nil
    end
    go(nearList[1], st.titles, #members > 0)
    return nearList[1]
end

function NQ.Press()
    if not OMQ.QuestPlaces then OMQ:Print("one more quest: no quest data"); return end
    -- again within a short time: the next place of the same list
    if last and now() - last.at < NQ.CYCLE and #last.list > 1 and OMQ.Guide and OMQ.Guide:Kind() == "omq" then
        last.idx = last.idx % #last.list + 1
        last.at = now()
        local members = NQ.Members()
        go(last.list[last.idx], last.titles, #members > 0)
        return last.list[last.idx]
    end
    local pos = myPos()
    if not pos then OMQ:Print("one more quest: no position here"); return end
    local log, titles = myLog()
    local members = NQ.Members()
    local st = { reqid = tostring(math.random(100000, 999999)), at = now(), members = members, replies = {},
                 log = log, titles = titles, pos = pos }
    st.avail = NQ.AvailableNear(pos, NQ.AVAIL_ASK, log)
    if #members == 0 then return NQ.Decide(st) end
    ask = st
    OMQ:Send("OQ", "a", st.reqid, OMQ:GetSelf() and OMQ:GetSelf().guid or "?", idsOf(st.avail, NQ.AVAIL_ASK))
    if C_Timer and C_Timer.After then C_Timer.After(NQ.ASK_WAIT, function() NQ.Finish(st.reqid) end) end
    return true
end

function NQ.Finish(reqid)
    if not ask or ask.reqid ~= reqid then return end
    local st = ask
    ask = nil
    return NQ.Decide(st)
end

OMQ:RegisterMessage("OQ", function(f)
    local op = f[1]
    local mine = OMQ:GetSelf()
    if op == "a" then
        if mine and f[3] == mine.guid then return end          -- my own question comes back to me
        -- somebody asks: which of my quests are done, which of these new ones can I take
        local log = myLog()
        local done = {}
        for id in pairs(log) do if NQ.IsComplete(id) then done[#done + 1] = id end end
        table.sort(done)
        local who = me()
        local can = {}
        for id in pairs(setOf(f[4])) do if NQ.CanTake(id, who, log) then can[#can + 1] = id end end
        table.sort(can)
        if mine then OMQ:Send("OQ", "r", f[2], mine.guid, idsOf(done, NQ.DONE_MAX), idsOf(can, NQ.AVAIL_ASK)) end
    elseif op == "r" then
        if not ask or ask.reqid ~= f[2] then return end
        ask.replies[f[3]] = { done = setOf(f[4]), avail = setOf(f[5]) }
        for _, u in ipairs(ask.members) do if not ask.replies[u.guid] then return end end
        NQ.Finish(ask.reqid)                                   -- everybody answered
    elseif op == "g" then
        if mine and f[2] == mine.guid then return end
        if OMQ.db.guide and OMQ.db.guide.receive == false then return end
        local a, b = tonumber(f[5]), tonumber(f[6])
        if not (a and b and OMQ.Guide) then return end
        OMQ.Guide:StartAt(f[3] ~= "" and f[3] or "One more quest", a, b, tonumber(f[7]) or 0, "omq", f[2],
            { name = f[4] ~= "" and f[4] or nil, radius = tonumber(f[8]) })
    end
end)

-- the top places for the button's tooltip (no asking, my own view)
function NQ.Preview(n)
    local pos = myPos()
    if not (pos and OMQ.QuestPlaces) then return {} end
    local log, titles = myLog()
    local members = NQ.Members()
    local list = NQ.Rank(NQ.LogCandidates((NQ.Common(log, members)), {}), pos)
    local out = {}
    for i = 1, math.min(n or 3, #list) do
        local title, what = NQ.Describe(list[i], titles)
        out[#out + 1] = { title = title, what = what, d = list[i].d }
    end
    return out
end

----------------------------------------------------------------------
-- Quest zones of the Journey (decision 296)
----------------------------------------------------------------------
NQ.HUB_CELL = 4                    -- map percent: quest givers in one cell form a hub
-- the zones for me: my faction and the contested ones
function NQ.Zones(fac)
    fac = fac or me().fac
    local out = {}
    for _, z in ipairs(OMQ.QuestZones or {}) do
        if z[4] == "C" or not fac or z[4] == fac then out[#out + 1] = z end
    end
    return out
end
function NQ.ZoneName(z)
    if C_Map and C_Map.GetMapInfo then
        local ok, i = pcall(C_Map.GetMapInfo, z[1])
        if ok and type(i) == "table" and type(i.name) == "string" and i.name ~= "" and not isSecret(i.name) then return i.name end
    end
    return z[5]
end
-- the quest hub of a zone: the cell with the most quest givers of my faction for the zone's levels
function NQ.ZoneHub(z, fac)
    fac = fac or me().fac
    local cells = {}
    for _, d in pairs(OMQ.QuestPlaces or {}) do
        local ql = d[3] or 0
        if d[7] and (not d[4] or not fac or d[4] == fac) and ql >= z[2] - 2 and ql <= z[3] + 2 then
            for _, s in ipairs(d[7]) do
                if s[1] == z[1] then
                    local k = math.floor(s[2] / NQ.HUB_CELL) .. ":" .. math.floor(s[3] / NQ.HUB_CELL)
                    local c = cells[k] or { 0, 0, 0 }
                    c[1], c[2], c[3] = c[1] + s[2], c[2] + s[3], c[3] + 1
                    cells[k] = c
                end
            end
        end
    end
    local best
    for _, c in pairs(cells) do if not best or c[3] > best[3] then best = c end end
    if not best then return { z[1], 50, 50, 0 } end
    return { z[1], best[1] / best[3], best[2] / best[3], best[3] }
end
-- how many quests I can take there now
function NQ.ZoneCount(z)
    local who, log = me(), (myLog())
    local n = 0
    for id, d in pairs(OMQ.QuestPlaces or {}) do
        local s = d[7] and d[7][1]
        if s and s[1] == z[1] and NQ.CanTake(id, who, log) then n = n + 1 end
    end
    return n
end
-- a click on a zone: the arrow to its quest hub
function NQ.GoZone(z)
    local hub = NQ.ZoneHub(z)
    local w = world(hub)
    if not (w and OMQ.Guide) then OMQ:Print("no position known for " .. NQ.ZoneName(z)); return false end
    local name = NQ.ZoneName(z)
    OMQ.Guide:StartAt(name, w[1], w[2], w[3], "zone", nil, { name = hub[4] > 0 and "quest hub" or "middle of the zone", radius = 30 })
    return true
end

----------------------------------------------------------------------
-- Diagnostics: /omq next diag
----------------------------------------------------------------------
function NQ.Diag()
    local out = { "One more quest - diagnostics" }
    local log = myLog()
    local n, with, dungeon = 0, 0, 0
    for id in pairs(log) do
        n = n + 1
        local d = data(id)
        if d then with = with + 1; if has(d[13], 8) then dungeon = dungeon + 1 end end
    end
    out[#out + 1] = string.format("quests in my log: %d, with places: %d, objectives in a dungeon: %d", n, with, dungeon)
    local members, without = NQ.Members()
    local common, unknown = NQ.Common(log, members)
    out[#out + 1] = string.format("dads with the addon: %d, without: %d, quests everybody has: %d", #members, without, #common)
    if #unknown > 0 then out[#out + 1] = "no quest list yet from: " .. table.concat(unknown, ", ") end
    local pos = myPos()
    out[#out + 1] = "position: " .. (pos and string.format("%.0f, %.0f, continent %s, map %s", pos.a, pos.b, tostring(pos.inst), tostring(pos.map)) or "none")
    if pos then
        local avail = NQ.AvailableNear(pos, 5, log)
        out[#out + 1] = string.format("new quests I could take nearby: %d shown", #avail)
        for _, p in ipairs(avail) do out[#out + 1] = string.format("  %s (%s)", titleOf(p.id), p.d and (math.floor(p.d) .. " yd") or "far") end
    end
    -- does this client know quest places itself? (decision 295: a probe for a later version)
    local api = {}
    for _, nme in ipairs({ "GetNextWaypoint", "GetQuestsOnMap", "GetQuestAdditionalHighlights" }) do
        api[#api + 1] = nme .. " " .. ((C_QuestLog and C_QuestLog[nme]) and "yes" or "no")
    end
    out[#out + 1] = "client quest places: " .. table.concat(api, ", ") .. ", QuestPOIGetIconInfo " .. (QuestPOIGetIconInfo and "yes" or "no")
    if OMQ.ShowReport then OMQ:ShowReport(out) else for _, l in ipairs(out) do print(l) end end
    return out
end

-- only the vote starts it (decision 302): "One more quest!" wins, the starter of the vote looks for the quest
OMQ:On("VOTE_END", function(result, by)
    local mine = OMQ:GetSelf()
    if result == "quest" and mine and by == mine.guid then NQ.Press() end
end)

OMQ:RegisterCommand("next", function(arg)
    arg = (arg or ""):lower()
    if arg == "diag" then NQ.Diag(); return end
    OMQ:Print("one more quest: start the vote with /omq - when \"One more quest!\" wins, the arrow leads to the next quest")
end, "one more quest: /omq next diag tells what the quest search sees")
