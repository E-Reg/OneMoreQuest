-- One More Quest: per-character counters
-- Counts what a character does over its whole life, kept in OMQDB.tally[guid]. Counters only, ids
-- instead of names (the same data on English and German clients). Every source is wrapped on its
-- own: a source that fails or returns secret values leaves only its own counter empty.
-- The combat log is blocked on this client, so kills come from PARTY_KILL; level, type and rank of
-- the victim come from a small in-memory cache filled whenever a unit is seen.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local T = {}
OMQ.Tally = T

local VERSION = 1
local CACHE_GEN = 200          -- units per cache generation (two generations are kept)
local XP_WINDOW = 1.5          -- seconds between a kill and an XP gain that proves the XP range
local RANGE_YARDS = 75         -- fallback when no XP comes (gray mobs, level 60)
local MAX_PEOPLE = 500
local MAX_VICTIMS = 200
local MAX_DEATHS = 500
local TALK_AGAIN = 60          -- one talk per NPC per minute
local MAX_STEP = 40            -- yards per second; larger jumps are teleports

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function str(v) return type(v) == "string" and ok(v) and v ~= "" end

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2)
end

T.diag = {}
local function note(key, n) T.diag[key] = (T.diag[key] or 0) + (n or 1) end

local dateFn = date or (os and os.date)
local function today() return dateFn and dateFn("%Y-%m-%d", time()) or "?" end

-- "Creature-0-1-2-3-3100-0000" -> "Creature", 3100; "Player-1-ABC" -> "Player"
local function parseGuid(guid)
    if not str(guid) then return nil end
    local kind = guid:match("^(%a+)%-")
    local id = guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    return kind, id and tonumber(id)
end
T.ParseGuid = parseGuid

local function myGuid() local me = OMQ:GetSelf(); return me and me.guid end
local function myLevel() return num(UnitLevel("player")) and UnitLevel("player") or 1 end

local function currentMap()
    local m = C_Map and call(C_Map.GetBestMapForUnit, "player")
    return num(m) and m or nil
end

-- party or raid members right now: { [guid] = unit }
local function mates()
    local list = {}
    local prefix, n = nil, 0
    if IsInRaid and IsInRaid() then prefix, n = "raid", 40
    elseif IsInGroup and IsInGroup() then prefix, n = "party", 4 end
    local me = myGuid()
    for i = 1, n do
        local u = prefix .. i
        if not UnitExists or UnitExists(u) then
            local g = UnitGUID(u)
            if str(g) and g ~= me then list[g] = u end
        end
    end
    return list
end
T.Mates = mates

----------------------------------------------------------------------
-- The book of this character
----------------------------------------------------------------------
local function pair() return { n = 0, m = 0 } end

local function newBook()
    return {
        v = VERSION,
        since = { t = time(), lvl = myLevel() },
        secs = 0,                          -- active seconds (not AFK) since the start
        kills = { total = 0, mine = 0, solo = 0, fullbag = 0, npc = {}, type = {}, lvl = {}, color = {}, rank = {}, rankOut = {} },
        zones = {},                        -- real zones (Barrens, Feralas), above sub maps
        pvp = { n = 0, color = {}, class = {}, race = {}, victims = {}, killedBy = { n = 0, color = {}, class = {}, players = {} } },
        npcs = {}, people = {}, maps = {}, quests = {}, deaths = {}, dungeons = {}, levels = {}, firsts = {},
        days = {}, spells = {}, support = { res = 0, buffOthers = 0, healOthers = 0 },
        move = { foot = 0, mount = 0, swim = 0, flights = 0, jumps = 0 },
        loot = {}, gather = { skin = 0, mine = 0, herb = 0, fish = 0, node = {} },
        prof = { crafted = 0 }, money = { repair = 0 }, afk = 0,
        records = { bestDayKills = 0, longestNoDeath = 0 },
        lastDeathSecs = 0, levelSecs = 0,
        tabs = {}, cards = {},
    }
end

local bookCache
local function book()
    local guid = myGuid()
    if not guid or not OMQDB then return nil end
    if bookCache and bookCache.guid == guid then return bookCache.b end
    OMQDB.tally = OMQDB.tally or {}
    local b = OMQDB.tally[guid]
    if type(b) ~= "table" or b.v ~= VERSION then
        b = newBook()
        OMQDB.tally[guid] = b
    end
    bookCache = { guid = guid, b = b }
    return b
end
T.Book = book
function T:_Reset() bookCache = nil end

local function day(b)
    local key = today()
    local d = b.days[key]
    if not d then
        d = { s = 0, afk = 0, l0 = myLevel(), l1 = myLevel(), k = 0, d = 0, q = 0, c = {}, r = {}, g = {} }
        b.days[key] = d
    end
    return d
end

local function first(b, key, extra)
    if b.firsts[key] then return end
    b.firsts[key] = { t = time(), l = myLevel(), m = currentMap(), x = extra }
    note("first")
end

local function inc(t, k, by) t[k] = (t[k] or 0) + (by or 1) end
local function incPair(t, k, mine)
    local p = t[k]
    if not p then p = pair(); t[k] = p end
    p.n = p.n + 1
    if mine then p.m = p.m + 1 end
end

----------------------------------------------------------------------
-- Unit cache: what a unit is, by GUID, seen before it dies
----------------------------------------------------------------------
local TYPES = {
    beast = "beast", wildtier = "beast", humanoid = "humanoid", undead = "undead", untoter = "undead",
    demon = "demon", ["dämon"] = "demon", elemental = "elemental", elementar = "elemental",
    dragonkin = "dragonkin", drachkin = "dragonkin", giant = "giant", riese = "giant",
    mechanical = "mechanical", mechanisch = "mechanical", critter = "critter", kleintier = "critter",
    totem = "totem", aberration = "aberration", ["not specified"] = "none", ["nicht spezifiziert"] = "none",
}
local RANKS = { normal = "normal", trivial = "normal", minus = "normal", elite = "elite", rare = "rare",
                rareelite = "rareelite", worldboss = "boss" }

local cur, old, curN = {}, {}, 0

local function lookup(guid) return cur[guid] or old[guid] end
T.Lookup = lookup

local function scan(unit)
    if not unit or (UnitExists and not call(UnitExists, unit)) then return end
    local guid = call(UnitGUID, unit)
    if not str(guid) then note("cache.secret"); return end
    local e = lookup(guid)
    if e and e.lvl then return e end
    e = {}
    local lvl = call(UnitLevel, unit)
    if num(lvl) then e.lvl = lvl else note("cache.nolevel") end
    local ct = call(UnitCreatureType, unit)
    if str(ct) then e.type = TYPES[ct:lower()] or "other" end
    local cl = call(UnitClassification, unit)
    if str(cl) then e.rank = RANKS[cl] or "normal" end
    if e.lvl == -1 and e.rank ~= "boss" then e.rank = "boss" end
    local name = call(UnitName, unit)
    if str(name) then e.name = name end
    local isPlayer = call(UnitIsPlayer, unit)
    if ok(isPlayer) and isPlayer then
        e.player = true
        local _, c = call(UnitClass, unit)
        if str(c) then e.class = c end
        local _, r = call(UnitRace, unit)
        if str(r) then e.race = r end
    end
    if curN >= CACHE_GEN then old, cur, curN = cur, {}, 0 end
    cur[guid] = e
    curN = curN + 1
    note("cache.add")
    return e
end
T.Scan = scan

----------------------------------------------------------------------
-- Colors as at the moment of the kill (classic rules)
----------------------------------------------------------------------
local function grayLevel(me)
    if me <= 5 then return 0 end
    if me <= 39 then return me - math.floor(me / 10) - 5 end
    if me <= 59 then return me - math.floor(me / 5) - 1 end
    return me - 9
end

local function color(lvl, me)
    if not lvl then return "unknown" end
    if lvl == -1 then return "skull" end
    local d = lvl - me
    if d >= 10 then return "skull" end
    if d >= 5 then return "red" end
    if d >= 3 then return "orange" end
    if d >= -2 then return "yellow" end
    if lvl > grayLevel(me) then return "green" end
    return "gray"
end
T.Color = color

----------------------------------------------------------------------
-- Kills
----------------------------------------------------------------------
local lastXp = -100
local bossSet

local EXTRA_BOSSES = { 1716, 10813 }    -- final bosses without a loot table in Data/DungeonLoot.lua
local function isBoss(id)
    if not bossSet then
        bossSet = {}
        for _, b in ipairs(EXTRA_BOSSES) do bossSet[b] = true end
        for _, list in pairs(OMQ.DungeonLoot or {}) do
            for _, boss in ipairs(list) do if boss[1] then bossSet[boss[1]] = true end end
        end
    end
    return id and bossSet[id] or false
end

local function freeSlots()
    if not (C_Container and C_Container.GetContainerNumFreeSlots) then return nil end
    local free = 0
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local n, family = call(C_Container.GetContainerNumFreeSlots, bag)
        if num(n) and (family == nil or family == 0) then free = free + n end
    end
    return free
end

local dungeon               -- the current dungeon visit (a row of b.dungeons)

local function record(victim, mine, killerIsMe)
    local b = book()
    if not b then return end
    local kind, id = parseGuid(victim)
    local e = lookup(victim)
    if not e then note("kill.nocache") end
    local me = myLevel()
    local grp = mates()
    local solo = next(grp) == nil
    local d = day(b)

    if kind == "Player" then
        local p = b.pvp
        p.n = p.n + 1
        local c = color(e and e.lvl, me)
        inc(p.color, c)
        local cls, race = e and e.class, e and e.race
        if not cls and GetPlayerInfoByGUID then
            local _, c2, _, r2 = call(GetPlayerInfoByGUID, victim)
            if str(c2) then cls = c2 end
            if str(r2) then race = r2 end
        end
        if cls then inc(p.class, cls) end
        if race then inc(p.race, race) end
        local v = p.victims[victim]
        if not v then
            local count = 0
            for _ in pairs(p.victims) do count = count + 1 end
            if count < MAX_VICTIMS then v = { n = 0, c = cls, t = time() }; p.victims[victim] = v end
        end
        if v then v.n = v.n + 1 end
        if killerIsMe then first(b, "pvpkill") end
        note("kill.pvp")
        return
    end

    local k = b.kills
    k.total = k.total + 1
    if mine then k.mine = k.mine + 1 end
    if solo then k.solo = k.solo + 1 end
    local free = freeSlots()
    if free == 0 then k.fullbag = k.fullbag + 1 end
    incPair(k.type, e and e.type or "unknown", mine)
    local lvl = e and e.lvl
    if lvl and lvl > 0 then incPair(k.lvl, lvl, mine) end
    local c = color(lvl, me)
    incPair(k.color, c, mine)
    local rank = e and e.rank or "unknown"
    if isBoss(id) then rank = "boss" end
    incPair(k.rank, rank, mine)
    local inside = IsInInstance and call(IsInInstance)
    if not (ok(inside) and inside) then
        k.rankOut = k.rankOut or {}
        incPair(k.rankOut, rank, mine)
    end
    if id then
        -- per mob: counts plus what it was (name as the client showed it, type, rank, levels, where, which days)
        local n = k.npc[id]
        if not n then
            n = { n = 0, m = 0, g = 0, dy = 0, t = time(), l = me, z = T.map }
            n.zn = n.z and T.ZoneOf and T.ZoneOf(n.z) or nil
            k.npc[id] = n
        end
        n.n = n.n + 1
        if mine then n.m = n.m + 1 end
        if e and e.name and not n.nm then n.nm = e.name end
        if e and e.type and not n.ty then n.ty = e.type end
        if rank ~= "unknown" then n.rk = rank end
        if lvl and lvl > 0 then
            if not n.lo or lvl < n.lo then n.lo = lvl end
            if not n.hi or lvl > n.hi then n.hi = lvl end
        end
        local key = today()
        if n.ld ~= key then n.dy = (n.dy or 0) + 1; n.ld = key end
        for g in pairs(grp) do
            if OMQ.users and OMQ.users[g] then n.g = (n.g or 0) + 1; break end
        end
    end
    if rank == "elite" or rank == "rareelite" then first(b, "elite", id) end
    if rank == "rare" or rank == "rareelite" then first(b, "rare", id) end
    if rank == "boss" then first(b, "boss", id) end

    d.k = d.k + 1
    inc(d.c, c)
    inc(d.r, rank)
    if d.k > b.records.bestDayKills then b.records.bestDayKills = d.k end
    local m = T.map and b.maps[T.map]
    if m then m.k = m.k + 1 end
    for g in pairs(grp) do
        local p = b.people[g]
        if p then p.k = (p.k or 0) + 1 end
    end
    if dungeon and (rank == "boss" or isBoss(id)) and id then
        local dads = 1
        for g in pairs(grp) do if OMQ.users and OMQ.users[g] then dads = dads + 1 end end
        dungeon.boss[id] = { t = time(), dads = dads }
    end
    note("kill")
end
T._Record = record

-- a kill by a group member counts when I was in XP range: an XP gain right before or after
-- the kill, else (gray mobs, max level) the distance to the killer
local function inRange(killer)
    if IsInInstance and call(IsInInstance) then note("kill.instance"); return true end
    local unit = mates()[killer]
    if not unit or not UnitPosition then return false end
    local y1, x1, _, i1 = call(UnitPosition, "player")
    local y2, x2, _, i2 = call(UnitPosition, unit)
    if not (num(x1) and num(y1) and num(x2) and num(y2)) or i1 ~= i2 then return false end
    local dist = math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
    if dist <= RANGE_YARDS then note("kill.dist"); return true end
    return false
end

local function onPartyKill(killer, victim)
    if not (str(killer) and str(victim)) then note("kill.secret"); return end
    scan("target"); scan("mouseover")
    local me = myGuid()
    local pet = call(UnitGUID, "pet")
    local mine = killer == me or (str(pet) and killer == pet)
    if mine then record(victim, true, killer == me); return end
    local grp = mates()
    local fromGroup = grp[killer] ~= nil
    if not fromGroup then
        -- a pet of a group member
        for _, u in pairs(grp) do
            local pg = call(UnitGUID, u .. "pet")
            if str(pg) and pg == killer then fromGroup = true; break end
        end
    end
    if not fromGroup then note("kill.foreign"); return end
    local at = GetTime()
    C_Timer.After(XP_WINDOW, function()
        local xp = lastXp >= at - XP_WINDOW and lastXp <= at + XP_WINDOW
        if xp then note("kill.xp") end
        if xp or inRange(killer) then
            record(victim, false, false)
        else
            note("kill.dropped")
        end
    end)
end
T._OnPartyKill = onPartyKill

----------------------------------------------------------------------
-- Places, dungeons, people
----------------------------------------------------------------------
-- the zone a map belongs to (caves and towns have their own maps)
local function zoneOf(id)
    if not (C_Map and C_Map.GetMapInfo) then return nil end
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    for _ = 1, 6 do
        local info = call(C_Map.GetMapInfo, id)
        if type(info) ~= "table" then return nil end
        if info.mapType == zoneType then return id end
        if not num(info.parentMapID) or info.parentMapID == 0 then return nil end
        id = info.parentMapID
    end
end
T.ZoneOf = zoneOf

local function enterMap()
    local b = book()
    if not b then return end
    local id = currentMap()
    local zone = id and zoneOf(id)
    if zone then
        b.zones = b.zones or {}
        if not b.zones[zone] then b.zones[zone] = { t = time(), l = myLevel() }; note("zone.new") end
    end
    if id then
        T.map = id
        local m = b.maps[id]
        if not m then
            m = { t = time(), l = myLevel(), s = 0, k = 0, d = 0, sub = {}, g = {} }
            b.maps[id] = m
            note("map.new")
        end
        local sub = call(GetSubZoneText)
        if str(sub) and not m.sub[sub] then m.sub[sub] = time() end
        for g in pairs(mates()) do m.g[g] = true end
    end
    -- dungeons
    local _, kind, _, _, _, _, _, instId = call(GetInstanceInfo)
    if (kind == "party" or kind == "raid") and num(instId) then
        if not dungeon or dungeon.id ~= instId or time() - (dungeon.seen or 0) > 3600 then
            dungeon = { id = instId, t = time(), l = myLevel(), boss = {}, g = {} }
            table.insert(b.dungeons, dungeon)
            first(b, "dungeon", instId)
            for g in pairs(mates()) do
                dungeon.g[g] = true
                local p = b.people[g]
                if p then p.dg = (p.dg or 0) + 1 end
            end
            note("dungeon")
        end
        dungeon.seen = time()
    elseif dungeon then
        dungeon.seen = time()
        dungeon = nil
    end
end
T._EnterMap = enterMap

local function trimPeople(b)
    local n, low, lowG = 0, nil, nil
    for g, p in pairs(b.people) do
        n = n + 1
        if not p.dad and (not low or (p.s or 0) < low) then low, lowG = p.s or 0, g end
    end
    if n > MAX_PEOPLE and lowG then b.people[lowG] = nil end
end

local function rosterUpdate()
    local b = book()
    if not b then return end
    for g, u in pairs(mates()) do
        local p = b.people[g]
        if not p then
            local name = call(UnitName, u)
            local _, cls = call(UnitClass, u)
            p = { nm = str(name) and name or nil, c = str(cls) and cls or nil, t = time(), s = 0,
                  k = 0, q = 0, d = 0, dg = 0, emo = {} }
            b.people[g] = p
            note("people.new")
            trimPeople(b)
        end
        if OMQ.users and OMQ.users[g] then p.dad = true end
        if dungeon and not dungeon.g[g] then dungeon.g[g] = true; p.dg = (p.dg or 0) + 1 end
    end
end
T._Roster = rosterUpdate

----------------------------------------------------------------------
-- NPCs, quests, deaths
----------------------------------------------------------------------
local lastTalk = {}
local function talk(kindName)
    local b = book()
    if not b then return end
    local guid = call(UnitGUID, "npc")
    local kind, id = parseGuid(guid)
    if not id or (kind ~= "Creature" and kind ~= "Vehicle") then return end
    local n = b.npcs[id]
    if not n then n = { n = 0, t = time(), l = myLevel(), k = {} }; b.npcs[id] = n; note("npc.new") end
    n.k[kindName] = true
    if GetTime() - (lastTalk[id] or -1000) >= TALK_AGAIN then
        n.n = n.n + 1
        lastTalk[id] = GetTime()
    end
    note("npc")
end
T._Talk = talk

local function questDone(questID)
    local b = book()
    if not b or not num(questID) then return end
    local q = { t = time(), l = myLevel(), m = currentMap(), g = {} }
    for g in pairs(mates()) do
        q.g[#q.g + 1] = g
        local p = b.people[g]
        if p then p.q = (p.q or 0) + 1 end
    end
    b.quests[questID] = q
    day(b).q = day(b).q + 1
    note("quest")
end
T._Quest = questDone

local breathAt                 -- when the breath timer started (drowning)
local ATTACKER_FOR = 15        -- seconds an attacker is remembered for a death
local plates = {}              -- nameplate units shown now
-- who hits me: a hostile nameplate that targets me, else my hostile target (on every hit I take)
local function noteAttacker()
    local function hostileOn(u)
        local g = call(UnitGUID, u)
        local h = call(UnitCanAttack, "player", u)
        return str(g) and ok(h) and h and g or nil
    end
    for u in pairs(plates) do
        local onMe = UnitIsUnit and call(UnitIsUnit, u .. "target", "player")
        if ok(onMe) and onMe then
            local g = hostileOn(u)
            if g then T.attacker = { guid = g, at = GetTime() }; scan(u); return end
        end
    end
    local g = hostileOn("target")
    if g then T.attacker = { guid = g, at = GetTime() } end
end
T._NoteAttacker = noteAttacker
local ENV = { "lava", "falld", "drownd" }
local ENV_WHY = { lava = "lava", falld = "fall", drownd = "drown" }
local envBase = {}
local function statValue(key)
    local ids = OMQ.Lifetime and OMQ.Lifetime.StatIds and OMQ.Lifetime:StatIds()
    local id = ids and ids[key]
    if not id or not GetStatistic then return nil end
    local v = call(GetStatistic, id)
    if not str(v) then return nil end
    local digits = v:gsub("[%s,%.]", "")
    return digits:match("^%d+$") and tonumber(digits) or nil
end
local function envSnapshot() for _, k in ipairs(ENV) do envBase[k] = statValue(k) end end
T._EnvSnapshot = envSnapshot
-- a few seconds after a death: did the game count it as lava, falling or drowning?
local function envResolve(d)
    for _, k in ipairs(ENV) do
        local now = statValue(k)
        if now and envBase[k] and now > envBase[k] then
            if k == "lava" or d.why == "unknown" or d.why == "npc" then d.why, d.id = ENV_WHY[k], nil end
            note("death.stat." .. k)
        end
    end
    envSnapshot()
end
local function onDeath()
    local b = book()
    if not b then return end
    local d = { t = time(), l = myLevel(), m = currentMap() }
    if d.m and C_Map and C_Map.GetPlayerMapPosition then
        local pos = call(C_Map.GetPlayerMapPosition, d.m, "player")
        if pos and pos.GetXY then
            local x, y = call(pos.GetXY, pos)
            if num(x) and num(y) then d.x, d.y = math.floor(x * 100 + 0.5), math.floor(y * 100 + 0.5) end
        end
    end
    local fi = OMQ.Measure and OMQ.Measure.fallInfo
    if fi and fi.fallingAt and GetTime() - fi.fallingAt <= 1.0 then
        d.why = "fall"
    elseif breathAt and GetTime() - breathAt >= 55 then
        d.why = "drown"
    else
        -- the hostile target now, else the last attacker seen (the client may drop the target at death)
        local tg = call(UnitGUID, "target")
        local hostile = call(UnitCanAttack, "player", "target")
        if not (str(tg) and ok(hostile) and hostile) then
            tg, hostile = nil, nil
            if T.attacker and GetTime() - T.attacker.at <= ATTACKER_FOR then tg, hostile = T.attacker.guid, true end
        end
        local kind, id = parseGuid(tg)
        if kind and hostile then
            if kind == "Player" then
                d.why = "player"
                local e = lookup(tg) or scan("target") or {}
                local kb = b.pvp.killedBy
                kb.n = kb.n + 1
                inc(kb.color, color(e.lvl, myLevel()))
                if e.class then inc(kb.class, e.class) end
                kb.players = kb.players or {}
                local kp = kb.players[tg]
                if not kp then
                    local count = 0
                    for _ in pairs(kb.players) do count = count + 1 end
                    if count < MAX_VICTIMS then kp = { n = 0, c = e.class, t = time() }; kb.players[tg] = kp end
                end
                if kp then kp.n = kp.n + 1 end
            else
                d.why, d.id = "npc", id
                local e = lookup(tg)
                d.c = color(e and e.lvl, myLevel())
            end
        else
            d.why = "unknown"
        end
    end
    if #b.deaths < MAX_DEATHS then table.insert(b.deaths, d) end
    local m = d.m and b.maps[d.m]
    if m then m.d = m.d + 1 end
    day(b).d = day(b).d + 1
    for g in pairs(mates()) do
        local p = b.people[g]
        if p then p.d = (p.d or 0) + 1 end
    end
    local streak = b.secs - (b.lastDeathSecs or 0)
    if streak > b.records.longestNoDeath then b.records.longestNoDeath = streak end
    b.lastDeathSecs = b.secs
    note("death." .. d.why)
    C_Timer.After(3, function() pcall(envResolve, d) end)
end
T._Death = onDeath

----------------------------------------------------------------------
-- Level splits
----------------------------------------------------------------------
local function profSnapshot()
    if not (GetProfessions and GetProfessionInfo) then return nil end
    local out = {}
    for _, idx in ipairs({ call(GetProfessions) }) do
        if num(idx) then
            local _, _, skill, _, _, _, line = call(GetProfessionInfo, idx)
            if num(skill) and num(line) then out[line] = skill end
        end
    end
    return next(out) and out or nil
end
T.ProfSnapshot = profSnapshot

local function levelUp(newLevel)
    local b = book()
    if not b then return end
    local lvl = num(newLevel) and newLevel or myLevel()
    local grp = {}
    for g in pairs(mates()) do grp[#grp + 1] = g end
    local gold = call(GetMoney)
    b.levels[lvl] = { t = time(), secs = b.secs, m = currentMap(), kills = b.kills.total, deaths = #b.deaths,
                      quests = 0, gold = num(gold) and gold or nil, prof = profSnapshot(), grp = grp }
    local q = 0
    for _ in pairs(b.quests) do q = q + 1 end
    b.levels[lvl].quests = q
    local took = b.secs - (b.levelSecs or 0)
    local fl = b.records.fastestLevel
    if took > 0 and lvl > b.since.lvl + 1 and (not fl or took < fl.s) then b.records.fastestLevel = { lvl = lvl, s = took } end
    b.levelSecs = b.secs
    day(b).l1 = lvl
    note("level")
end
T._LevelUp = levelUp

----------------------------------------------------------------------
-- Spells: counts, support for others, gathering
----------------------------------------------------------------------
-- base spells; every rank is matched by name, so the client's language does not matter
local SPELL_KIND = {
    [2006] = "res", [7328] = "res", [2008] = "res", [20484] = "res", [20707] = "res",
    [2050] = "heal", [2054] = "heal", [2060] = "heal", [2061] = "heal", [139] = "heal", [596] = "heal",
    [5185] = "heal", [774] = "heal", [8936] = "heal", [635] = "heal", [19750] = "heal", [331] = "heal",
    [8004] = "heal", [1064] = "heal",
    [2366] = "herb", [2575] = "mine", [8613] = "skin",
}
local kindByName
local function spellKind(id)
    if SPELL_KIND[id] then return SPELL_KIND[id] end
    if not kindByName then
        kindByName = {}
        for sid, k in pairs(SPELL_KIND) do
            local n = C_Spell and call(C_Spell.GetSpellName, sid)
            if str(n) then kindByName[n] = k end
        end
    end
    local n = C_Spell and call(C_Spell.GetSpellName, id)
    return str(n) and kindByName[n] or nil
end
T.SpellKind = spellKind

local function helpful(id)
    if C_Spell and C_Spell.IsSpellHelpful then
        local h = call(C_Spell.IsSpellHelpful, id)
        if ok(h) then return h and true or false end
    end
    return nil
end

local sentTarget = {}          -- castGUID -> target name (UNIT_SPELLCAST_SENT)
local lastGather, lastGatherAt = nil, -100

local function onSent(unit, target, castGUID)
    if unit ~= "player" or not str(castGUID) then return end
    sentTarget[castGUID] = str(target) and target or nil
end

local function onCast(unit, castGUID, spellID)
    if unit ~= "player" then return end
    if not num(spellID) then note("spell.secret"); return end
    local b = book()
    if not b then return end
    inc(b.spells, spellID)
    note("spell")
    local kind = spellKind(spellID)
    if kind == "herb" or kind == "mine" or kind == "skin" then
        b.gather[kind] = b.gather[kind] + 1
        lastGather, lastGatherAt = kind, GetTime()
        note("gather")
    end
    local target = str(castGUID) and sentTarget[castGUID]
    if str(castGUID) then sentTarget[castGUID] = nil end
    local myName = call(UnitName, "player")
    if not target or target == myName then return end
    -- only group members count as "others"
    local isMate = false
    for _, u in pairs(mates()) do
        if call(UnitName, u) == target then isMate = true; break end
    end
    if not isMate then return end
    if kind == "res" then b.support.res = b.support.res + 1
    elseif kind == "heal" then b.support.healOthers = b.support.healOthers + 1
    elseif helpful(spellID) ~= false then b.support.buffOthers = b.support.buffOthers + 1 end
    note("support")
end
T._Sent, T._Cast = onSent, onCast

----------------------------------------------------------------------
-- Loot, crafting, gathering nodes
----------------------------------------------------------------------
local QUALITY = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5 }
local function toPattern(fmt)
    if not str(fmt) then return nil end
    local p = fmt:gsub("%%%d?%$?s", "\001"):gsub("%%%d?%$?d", "\002")
    p = p:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    return "^" .. p
end
local patLoot, patCreate
local function patterns()
    if patLoot then return end
    local function list(...)
        local out = {}
        for i = 1, select("#", ...) do local p = toPattern((select(i, ...))); if p then out[#out + 1] = p end end
        return out
    end
    patLoot = list(LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF)
    patCreate = list(LOOT_ITEM_CREATED_SELF_MULTIPLE, LOOT_ITEM_CREATED_SELF)
end
local function matches(list, msg)
    for _, p in ipairs(list) do if msg:match(p) then return true end end
    return false
end

local function onLootMsg(msg)
    if not str(msg) then return end
    local b = book()
    if not b then return end
    patterns()
    note("loot.msg")
    -- quality: newer clients write "|cnIQ3:", older ones the color "|cff0070dd"; else ask the game
    local q = tonumber(msg:match("|cnIQ(%d):"))
    if not q then
        local hex = msg:match("|cff(%x%x%x%x%x%x)|Hitem:")
        q = hex and QUALITY[hex:lower()]
    end
    if not q and C_Item and C_Item.GetItemQualityByID then
        local id = tonumber(msg:match("|Hitem:(%d+)"))
        local iq = id and call(C_Item.GetItemQualityByID, id)
        if num(iq) then q = iq end
    end
    if matches(patCreate, msg) then
        b.prof.crafted = b.prof.crafted + 1
        if not b.prof.first then b.prof.first = time() end
        note("craft")
    elseif matches(patLoot, msg) and q then
        inc(b.loot, q)
        if q == 3 then first(b, "blue") elseif q == 4 then first(b, "epic") end
        note("loot")
    elseif matches(patLoot, msg) then
        note("loot.noquality")
    end
end
T._LootMsg = onLootMsg

local function onLootOpened()
    local b = book()
    if not b then return end
    if IsFishingLoot and call(IsFishingLoot) then b.gather.fish = b.gather.fish + 1; note("gather.fish"); return end
    if GetTime() - lastGatherAt > 5 or not (GetLootSourceInfo and GetNumLootItems) then return end
    local n = call(GetNumLootItems)
    if not num(n) or n < 1 then return end
    local guid = call(GetLootSourceInfo, 1)
    local kind, id = parseGuid(guid)
    if kind == "GameObject" and id then inc(b.gather.node, id); note("gather.node") end
    lastGatherAt = -100
end
T._LootOpened = onLootOpened

----------------------------------------------------------------------
-- Repairs
----------------------------------------------------------------------
local merchant, repairCost, repairPending, moneyDrop, lastMoney = false, 0, 0, 0, nil
local function cost() local c = call(GetRepairAllCost); return num(c) and c or 0 end
local function checkRepair()
    if not merchant then return end
    local c = cost()
    if c < repairCost then repairPending = repairPending + (repairCost - c) end
    repairCost = c
end
local function bookRepair()
    local spent = math.min(repairPending, moneyDrop)
    if spent > 0 then
        local b = book()
        if b then b.money.repair = b.money.repair + spent; note("repair") end
        repairPending, moneyDrop = repairPending - spent, moneyDrop - spent
    end
end
local function onMoney()
    local m = call(GetMoney)
    if not num(m) then return end
    if merchant and lastMoney and m < lastMoney then moneyDrop = moneyDrop + (lastMoney - m) end
    lastMoney = m
    checkRepair()
    if merchant then bookRepair() end
end
local function merchantShow() merchant = true; repairCost = cost(); repairPending, moneyDrop = 0, 0; local m = call(GetMoney); lastMoney = num(m) and m or nil end
local function merchantClosed() checkRepair(); bookRepair(); merchant = false; repairPending, moneyDrop = 0, 0 end
T._MerchantShow, T._MerchantClosed, T._Money, T._Durability = merchantShow, merchantClosed, onMoney, function() checkRepair(); bookRepair() end

----------------------------------------------------------------------
-- Every second: time per place, day, people, AFK, movement
----------------------------------------------------------------------
local lastX, lastY, lastInst, wasTaxi = nil, nil, nil, false
local function tick()
    local b = book()
    if not b then return end
    local d = day(b)
    local afk = UnitIsAFK and call(UnitIsAFK, "player")
    if ok(afk) and afk then
        b.afk = b.afk + 1
        d.afk = d.afk + 1
        lastX = nil
        return
    end
    b.secs = b.secs + 1
    d.s = d.s + 1
    d.l1 = myLevel()
    local m = T.map and b.maps[T.map]
    if m then m.s = m.s + 1 end
    for g in pairs(mates()) do
        local p = b.people[g]
        if p then p.s = (p.s or 0) + 1 end
        d.g[g] = true
    end
    -- movement
    local taxi = UnitOnTaxi and call(UnitOnTaxi, "player")
    taxi = ok(taxi) and taxi and true or false
    if taxi and not wasTaxi then b.move.flights = b.move.flights + 1 end
    wasTaxi = taxi
    local mounted = IsMounted and call(IsMounted)
    if ok(mounted) and mounted then first(b, "mount") end
    if not UnitPosition then return end
    local y, x, _, inst = call(UnitPosition, "player")
    if not (num(x) and num(y)) or taxi then lastX = nil; return end
    if lastX and inst == lastInst then
        local dist = math.sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2)
        if dist <= MAX_STEP and dist > 0 then
            local swim = IsSwimming and call(IsSwimming)
            local key = (ok(swim) and swim) and "swim" or ((ok(mounted) and mounted) and "mount" or "foot")
            b.move[key] = b.move[key] + dist
        end
    end
    lastX, lastY, lastInst = x, y, inst
end
T._Tick = tick

----------------------------------------------------------------------
-- Streak and explored map overlays (read from the game, nothing stored)
----------------------------------------------------------------------
-- days since a fixed date (civil calendar), so consecutive days differ by one
local function dayNumber(y, m, d)
    if m <= 2 then y, m = y - 1, m + 12 end
    return 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + math.floor((153 * (m - 3) + 2) / 5) + d
end
T.DayNumber = dayNumber

function T:Streak()
    local b = book()
    if not b or not dateFn then return 0, 0 end
    local now = time()
    local cur, best, run = 0, 0, 0
    local function key(t) return dateFn("%Y-%m-%d", t) end
    -- walk back from today for the current streak
    local t = now
    if not b.days[key(t)] then t = t - 86400 end
    while b.days[key(t)] do cur = cur + 1; t = t - 86400 end
    -- longest: sorted keys, consecutive day numbers
    local keys = {}
    for k in pairs(b.days) do keys[#keys + 1] = k end
    table.sort(keys)
    local prev
    for _, k in ipairs(keys) do
        local y, mo, dd = k:match("^(%d+)%-(%d+)%-(%d+)$")
        local n = y and dayNumber(tonumber(y), tonumber(mo), tonumber(dd))
        if n and prev and n == prev + 1 then run = run + 1 else run = 1 end
        prev = n
        if run > best then best = run end
    end
    return cur, best
end

-- a value of the game's statistics tab by the key Stats/Lifetime.lua found it under (aucp, aucg, deaths ...)
function T:GameStat(key) return statValue(key) end

function T:Explored(mapID)
    if not (C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures) then return nil end
    local list = call(C_MapExplorationInfo.GetExploredMapTextures, mapID)
    return type(list) == "table" and #list or nil
end

----------------------------------------------------------------------
-- Jumps and emotes
----------------------------------------------------------------------
local function onJump()
    if IsFalling and call(IsFalling) then return end
    local b = book()
    if b then b.move.jumps = b.move.jumps + 1 end
end
local function onEmote(token)
    if not str(token) then return end
    local b = book()
    if not b then return end
    local g = call(UnitGUID, "target")
    local p = str(g) and b.people[g]
    if p then
        p.emo = p.emo or {}
        inc(p.emo, token:lower())
        note("emote")
    end
end
T._Jump, T._Emote = onJump, onEmote

----------------------------------------------------------------------
-- Wiring: every handler on its own
----------------------------------------------------------------------
local function login()
    local b = book()
    if not b then return end
    day(b)
    rosterUpdate()
    enterMap()
end

local EVENTS = {
    PARTY_KILL = onPartyKill,
    PLAYER_XP_UPDATE = function() lastXp = GetTime() end,
    CHAT_MSG_COMBAT_XP_GAIN = function() lastXp = GetTime() end,
    PLAYER_TARGET_CHANGED = function() scan("target") end,
    UPDATE_MOUSEOVER_UNIT = function() scan("mouseover") end,
    PLAYER_FOCUS_CHANGED = function() scan("focus") end,
    NAME_PLATE_UNIT_ADDED = function(unit) if unit then plates[unit] = true end; scan(unit) end,
    NAME_PLATE_UNIT_REMOVED = function(unit) if unit then plates[unit] = nil end end,
    UNIT_COMBAT = function(unit, action) if unit == "player" and action == "WOUND" then noteAttacker() end end,
    UNIT_TARGET = function(unit) if unit and unit ~= "player" then scan(unit .. "target") end end,
    ZONE_CHANGED_NEW_AREA = enterMap,
    ZONE_CHANGED = enterMap,
    ZONE_CHANGED_INDOORS = enterMap,
    PLAYER_ENTERING_WORLD = function() login() end,
    GROUP_ROSTER_UPDATE = rosterUpdate,
    GOSSIP_SHOW = function() talk("gossip") end,
    QUEST_GREETING = function() talk("quest") end,
    QUEST_DETAIL = function() talk("quest") end,
    QUEST_PROGRESS = function() talk("quest") end,
    QUEST_COMPLETE = function() talk("quest") end,
    MERCHANT_SHOW = function() talk("vendor"); merchantShow() end,
    MERCHANT_CLOSED = merchantClosed,
    TRAINER_SHOW = function() talk("trainer") end,
    TAXIMAP_OPENED = function() talk("flight") end,
    BANKFRAME_OPENED = function() talk("bank") end,
    CONFIRM_BINDER = function() talk("innkeeper") end,
    AUCTION_HOUSE_SHOW = function() talk("auction") end,
    QUEST_TURNED_IN = questDone,
    PLAYER_DEAD = onDeath,
    MIRROR_TIMER_START = function(kind) if kind == "BREATH" then breathAt = breathAt or GetTime() end end,
    MIRROR_TIMER_STOP = function(kind) if kind == "BREATH" then breathAt = nil end end,
    PLAYER_LEVEL_UP = levelUp,
    UNIT_SPELLCAST_SENT = onSent,
    UNIT_SPELLCAST_SUCCEEDED = onCast,
    CHAT_MSG_LOOT = onLootMsg,
    LOOT_OPENED = onLootOpened,
    PLAYER_MONEY = onMoney,
    UPDATE_INVENTORY_DURABILITY = T._Durability,
}

local frame = CreateFrame("Frame")
for e in pairs(EVENTS) do pcall(frame.RegisterEvent, frame, e) end
frame:SetScript("OnEvent", function(_, event, ...)
    if not T.ready then return end
    local fine, err = pcall(EVENTS[event], ...)
    if not fine then note("err." .. event); OMQ:Error("tally " .. event, err) end
end)

OMQ:On("READY", function()
    T.ready = true
    pcall(login)
    C_Timer.After(10, function() pcall(envSnapshot) end)
    C_Timer.NewTicker(1, function()
        local fine, err = pcall(tick)
        if not fine then note("err.tick"); OMQ:Error("tally tick", err) end
    end)
    if hooksecurefunc then
        if JumpOrAscendStart then pcall(hooksecurefunc, "JumpOrAscendStart", function() pcall(onJump) end) end
        if DoEmote then pcall(hooksecurefunc, "DoEmote", function(token) pcall(onEmote, token) end) end
    end
end)

----------------------------------------------------------------------
-- Test output (temporary, not listed in /omq help)
----------------------------------------------------------------------
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
local function top(t, field, n)
    local list = {}
    for k, v in pairs(t or {}) do list[#list + 1] = { k = k, v = type(v) == "table" and (v[field] or 0) or v } end
    table.sort(list, function(a, c) return a.v > c.v end)
    local out = {}
    for i = 1, math.min(n, #list) do out[#out + 1] = tostring(list[i].k) .. "=" .. math.floor(list[i].v) end
    return table.concat(out, " ")
end
local function pairs2(t)
    local out = {}
    for k, v in pairs(t or {}) do out[#out + 1] = k .. "=" .. v.n .. "/" .. v.m end
    table.sort(out)
    return table.concat(out, " ")
end

function T:Report(part)
    local b = book()
    if not b then OMQ:Print("no character yet"); return end
    part = (part or ""):lower()
    if part == "diag" then
        local keys = {}
        for k in pairs(T.diag) do keys[#keys + 1] = k end
        table.sort(keys)
        OMQ:Print("tally diag (since login)")
        local line = {}
        for _, k in ipairs(keys) do line[#line + 1] = k .. "=" .. T.diag[k] end
        print("  " .. (#line > 0 and table.concat(line, " ") or "nothing yet"))
        print("  cache " .. count(cur) .. "+" .. count(old) .. ", map " .. tostring(T.map) .. ", dungeon " .. tostring(dungeon and dungeon.id))
        return
    end
    local k = b.kills
    OMQ:Print("tally since level " .. b.since.lvl .. ", active " .. math.floor(b.secs / 60) .. " min, afk " .. math.floor(b.afk / 60) .. " min")
    if part == "" or part == "kills" then
        print(string.format("  kills %d (mine %d, solo %d, full bags %d), npcs %d", k.total, k.mine, k.solo, k.fullbag, count(k.npc)))
        print("  color " .. pairs2(k.color))
        print("  rank " .. pairs2(k.rank))
        print("  type " .. pairs2(k.type))
        print("  top npcs " .. top(k.npc, "n", 5))
    end
    if part == "" or part == "pvp" then
        print(string.format("  pvp %d, killed by players %d, color %s", b.pvp.n, b.pvp.killedBy.n, top(b.pvp.color, nil, 6)))
    end
    if part == "" or part == "world" then
        print(string.format("  maps %d, npcs talked %d, quests %d, deaths %d, dungeons %d, people %d",
            count(b.maps), count(b.npcs), count(b.quests), #b.deaths, #b.dungeons, count(b.people)))
        print("  time per map (min) " .. top(b.maps, "s", 5):gsub("=(%d+)", function(s) return "=" .. math.floor(tonumber(s) / 60) end))
        local last = b.deaths[#b.deaths]
        if last then print("  last death: " .. tostring(last.why) .. " " .. tostring(last.id or "") .. " map " .. tostring(last.m)) end
    end
    if part == "" or part == "more" then
        local cs, best = T:Streak()
        print(string.format("  days %d, streak %d (best %d), level splits %d, firsts %d", count(b.days), cs, best, count(b.levels), count(b.firsts)))
        print(string.format("  spells %d kinds, top %s", count(b.spells), top(b.spells, nil, 4)))
        print(string.format("  support res %d heal %d buff %d", b.support.res, b.support.healOthers, b.support.buffOthers))
        print(string.format("  move foot %d mount %d swim %d yd, flights %d, jumps %d",
            b.move.foot, b.move.mount, b.move.swim, b.move.flights, b.move.jumps))
        print(string.format("  loot %s, crafted %d, repair %dc", top(b.loot, nil, 6), b.prof.crafted, b.money.repair))
        print(string.format("  gather skin %d mine %d herb %d fish %d, nodes %s", b.gather.skin, b.gather.mine,
            b.gather.herb, b.gather.fish, top(b.gather.node, nil, 3)))
        local m = T.map and T:Explored(T.map)
        if m then print("  explored overlays here: " .. m) end
    end
end

OMQ:RegisterCommand("tally", function(arg) T:Report(arg) end, nil, true)
