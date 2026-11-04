-- One More Quest: lifetime values (section 3.4)
-- Summed from every saved session of this character plus the game's own
-- statistics tab. Shared with the group like the session values, and the last
-- known values of other players are kept so offline players stay in the window.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local SEND_INTERVAL = 60
local STAT_SCAN_EVERY = 600
local MIN_SESSION = 600
local KEYS = { "ptime", "gold", "yards", "xp", "quests", "kb", "deaths", "falld", "drownd", "fallx", "near",
               "hit", "bestxph", "longest", "bestgold", "xpkill", "xpquest", "xpdisc", "aucp", "aucb" }
-- sent in a second message so the first one stays short enough (decision 120)
local KEYS2 = { "xph", "food", "fights", "heal", "lava", "mostdeaths", "need", "greed", "gamble", "betswon", "yfollow" }
OMQ.lifeKeys = KEYS

local L = {}
OMQ.Lifetime = L

----------------------------------------------------------------------
-- Own values from the saved sessions
----------------------------------------------------------------------
-- Only the sessions of THIS character (decision: everything is kept per character)
local function allSessions()
    local list = {}
    local me = OMQ:GetSelf()
    local guid = me and me.guid
    if not guid then return list end
    for _, s in ipairs((OMQDB.history or {})[guid] or {}) do list[#list + 1] = s end
    local current = (OMQDB.sessions or {})[guid]
    if current then list[#list + 1] = current end
    return list
end

local function fromSessions()
    local v = { ptime = 0, gold = 0, yards = 0, yfollow = 0, xp = 0, kb = 0, near = 0,
                hit = 0, bestxph = 0, longest = 0, bestgold = 0 }
    local tracked = false      -- any session that knows XP by source (since 0.14.0)
    local food, online = 0, 0
    for _, s in ipairs(allSessions()) do
        local dur = math.max(0, (s.lastActive or 0) - (s.start or 0))
        v.ptime = v.ptime + dur
        v.gold = v.gold + (s.goldGained or 0)
        v.yards = v.yards + (s.yards or 0)
        v.yfollow = v.yfollow + (s.yardsFollow or 0)
        v.xp = v.xp + (s.xpGained or 0)
        v.kb = v.kb + (s.kills or 0)
        if s.fallDmg ~= nil then v.fallx = (v.fallx or 0) + s.fallDmg end
        if s.xpQuest ~= nil and s.xpDisc ~= nil then
            tracked = true
            v.xpquest = (v.xpquest or 0) + s.xpQuest
            v.xpdisc = (v.xpdisc or 0) + s.xpDisc
            v.xpkill = (v.xpkill or 0) + math.max(0, (s.xpGained or 0) - s.xpQuest - s.xpDisc)
        end
        v.near = v.near + (s.nearDeaths or 0)
        v.sdeaths = (v.sdeaths or 0) + (s.deaths or 0)
        if (s.deaths or 0) > (v.mostdeaths or 0) then v.mostdeaths = s.deaths end
        v.need = (v.need or 0) + (s.needRolls or 0)
        v.greed = (v.greed or 0) + (s.greedRolls or 0)
        v.gamble = (v.gamble or 0) + (s.gamble or 0)
        v.betswon = (v.betswon or 0) + (s.betsWon or 0)
        if s.quests ~= nil then v.squests = (v.squests or 0) + s.quests end
        if s.fights ~= nil then v.fights = (v.fights or 0) + s.fights end
        if (s.bestHeal or 0) > (v.heal or 0) then v.heal = s.bestHeal end
        food = food + (s.foodSeconds or 0)
        online = online + (s.onlineSeconds or 0)
        if (s.biggestHit or 0) > v.hit then v.hit = s.biggestHit end
        if dur > v.longest then v.longest = dur end
        if (s.goldGained or 0) > v.bestgold then v.bestgold = s.goldGained end
        if dur >= MIN_SESSION then
            local xph = (s.xpGained or 0) / (dur / 3600)
            if xph > v.bestxph then v.bestxph = xph end
        end
    end
    if online > 0 then v.food = food / online * 100 end
    if v.ptime > 0 then v.xph = v.xp / (v.ptime / 3600) end
    v.mostdeaths = v.mostdeaths or 0
    return v
end

----------------------------------------------------------------------
-- The game's statistics tab, found by name (English and German clients)
----------------------------------------------------------------------
local function has(name, list)
    for _, w in ipairs(list) do if name:find(w, 1, true) then return true end end
    return false
end

local DEATH_W   = { "death", "tode", "tod " }
local FALL_W    = { "falling", "fall ", "sturz", "fallen" }
local DROWN_W   = { "drown", "ertrink" }
local LAVA_W    = { "lava" }
local ROLL_W    = { "roll", "würfe", "wurf", "würfel" }
local NEED_W    = { "need", "bedarf" }
local GREED_W   = { "greed", "gier" }
local DAMAGE_W  = { "damage", "schaden" }

-- returns the key a statistic name belongs to, or nil
local AUCTION_W = { "auction", "auktion" }
local MONEY_W   = { "gold", "money", "geld", "copper", "kupfer" }
local POSTED_W  = { "posted", "created", "eingestellt", "erstellt" }
local EARNED_W  = { "earned", "made", "sold", "verdient", "eingenommen", "verkauf" }
local BOUGHT_W  = { "won", "purchase", "bought", "gewonnen", "gekauft", "erworben", "käufe" }

local function classify(name)
    local n = name:lower()
    if has(n, AUCTION_W) and has(n, MONEY_W) and has(n, EARNED_W) then return "aucg" end
    if has(n, AUCTION_W) and not has(n, MONEY_W) then
        if has(n, POSTED_W) then return "aucp" end
        if has(n, BOUGHT_W) then return "aucb" end
    end
    if has(n, ROLL_W) and not has(n, MONEY_W) and not has(n, DEATH_W) then
        if has(n, NEED_W) then return "need" end
        if has(n, GREED_W) then return "greed" end
    end
    if n == "total deaths" or n == "tode insgesamt" or n == "gesamtzahl der tode" or n == "anzahl der tode" then return "deaths" end
    if has(n, DROWN_W) and has(n, DEATH_W) then return "drownd" end
    if has(n, LAVA_W) and has(n, DEATH_W) then return "lava" end
    if has(n, FALL_W) and has(n, DEATH_W) then return "falld" end
    if has(n, FALL_W) and has(n, DAMAGE_W) and not has(n, DEATH_W) then return "fallx" end
    if n == "quests completed" or n == "completed quests" or n == "abgeschlossene quests" or n == "quests abgeschlossen" then return "quests" end
end

local function parseNumber(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return nil end
    local digits = v:gsub("[%s,%.]", "")
    if digits:match("^%d+$") then return tonumber(digits) end
end

-- The scan walks every entry of the statistics tab. On retail that is well over a thousand
-- entries and took one to two seconds in one go: the game stood still at the first hover over
-- the minimap icon (decision 374). Now the scan runs in the background a few milliseconds per
-- frame, the ids found are kept per client language, and readers only use what is known.
local SCAN_BUDGET_MS = 3      -- per frame
local SCAN_BUDGET_N = 40      -- per frame without a timer
local statIds, statScanAt = {}, -math.huge
local scanJob, scanFrame

local function statApi()
    return GetStatisticsCategoryList and GetCategoryNumAchievements and GetAchievementInfo and GetStatistic
end

local function cacheKey()
    local build
    if GetBuildInfo then build = select(4, GetBuildInfo()) end
    return (GetLocale and GetLocale() or "?") .. "|" .. tostring(build or "?")
end

-- one category entry: name -> key; the first id per key wins
local function classifyEntry(found, cat, i)
    local oka, id, name = pcall(GetAchievementInfo, cat, i)
    if oka and id and type(name) == "string" then
        local key = classify(name)
        if key and not found[key] then found[key] = id end
    end
end

local function finishScan(found)
    -- the auction rows have fixed ids in the statistics tab (329 posted, 330 bought)
    for key, id in pairs({ aucp = 329, aucb = 330 }) do
        if not found[key] then
            local okv, val = pcall(GetStatistic, id)
            if okv and parseNumber(val) then found[key] = id end
        end
    end
    statIds = found
    if OMQDB then OMQDB.statIds = { key = cacheKey(), ids = found } end
    if OMQ.Fire then OMQ:Fire("STATISTICS_SCANNED") end
end

-- the whole tab in one go (/omq lifetime scan and the tests)
local function scanNow()
    if not statApi() then return end
    statScanAt = GetTime()
    scanJob = nil
    local ok, cats = pcall(GetStatisticsCategoryList)
    if not ok or type(cats) ~= "table" then return end
    local found = {}
    for _, cat in ipairs(cats) do
        local okn, num = pcall(GetCategoryNumAchievements, cat)
        for i = 1, (okn and num) or 0 do classifyEntry(found, cat, i) end
    end
    finishScan(found)
end

local function scanStep()
    local job = scanJob
    if not job then if scanFrame then scanFrame:SetScript("OnUpdate", nil) end; return end
    local clock = debugprofilestop
    local t0 = clock and clock()
    local n = 0
    while true do
        local cat = job.cats[job.c]
        if not cat then
            scanJob = nil
            scanFrame:SetScript("OnUpdate", nil)
            finishScan(job.found)
            return
        end
        if not job.num then
            local okn, num = pcall(GetCategoryNumAchievements, cat)
            job.num, job.i = (okn and num) or 0, 1
        end
        if job.i > job.num then
            job.c, job.num = job.c + 1, nil
        else
            classifyEntry(job.found, cat, job.i)
            job.i = job.i + 1
        end
        n = n + 1
        if t0 then
            if n % 10 == 0 and clock() - t0 >= SCAN_BUDGET_MS then return end
        elseif n >= SCAN_BUDGET_N then return end
    end
end

-- starts a background scan when the last one is old enough (or force)
local function scanStatistics(force)
    if scanJob or not statApi() then return end
    if not force and GetTime() - statScanAt < STAT_SCAN_EVERY then return end
    statScanAt = GetTime()
    local ok, cats = pcall(GetStatisticsCategoryList)
    if not ok or type(cats) ~= "table" then return end
    scanJob = { cats = cats, c = 1, found = {} }
    scanFrame = scanFrame or CreateFrame("Frame")
    scanFrame:SetScript("OnUpdate", scanStep)
end

-- ids from the last login with the same client: usable at once, before any scan
local function loadCachedIds()
    local c = OMQDB and OMQDB.statIds
    if type(c) == "table" and c.key == cacheKey() and type(c.ids) == "table" and next(statIds) == nil then
        statIds = c.ids
    end
end

local function fromStatistics()
    local v = {}
    for key, id in pairs(statIds) do
        local ok, val = pcall(GetStatistic, id)
        if ok then v[key] = parseNumber(val) end
    end
    return v
end

-- a death counter of the statistics tab as a number: the game shows "--" until the first such death,
-- that is 0 here (decision 401: the first drowning or lava death of a character was never counted,
-- because "--" was no data and the next read "1" became the start value). nil: no such statistic.
local COUNTERS = { falld = true, drownd = true, lava = true }
function L:StatCount(key)
    loadCachedIds()
    local id = statIds[key]
    if not id then return nil end
    local ok, val = pcall(GetStatistic, id)
    if not ok then return nil end
    local n = parseNumber(val)
    if n then return n end
    if COUNTERS[key] and (val == nil or (type(val) == "string" and val:match("^[%s%-]*$"))) then return 0 end
    return nil
end

function L:RescanStatistics() scanNow() end
function L:ScanInBackground(force) scanStatistics(force) end
function L:IsScanning() return scanJob ~= nil end
function L:StatIds() return statIds end

-- the game's own counters (deaths, auctions ...), nil where the client has none
function L:GetStatValues()
    loadCachedIds()
    scanStatistics()
    return fromStatistics()
end

function L:GetValues()
    loadCachedIds()
    scanStatistics()
    local v = fromSessions()
    -- without the game's own counters the saved sessions have to do
    if v.sdeaths then v.deaths = v.sdeaths end
    if v.squests then v.quests = v.squests end
    for k, x in pairs(fromStatistics()) do v[k] = x end
    v.sdeaths, v.squests = nil, nil
    return v
end

----------------------------------------------------------------------
-- Sharing
----------------------------------------------------------------------
local function enc(v)
    if type(v) ~= "number" or v ~= v then return "" end
    return string.format("%.0f", v)
end

function L:Send()
    local me = OMQ:GetSelf()
    if not me or not OMQ:GetChannel() then return end
    local v = self:GetValues()
    local f = { me.guid }
    for i, k in ipairs(KEYS) do f[i + 1] = enc(v[k]) end
    OMQ:Send("L", unpack(f))
    local g = { me.guid }
    for i, k in ipairs(KEYS2) do g[i + 1] = enc(v[k]) end
    OMQ:Send("L2", unpack(g))
end

local function handle(fields)
    local guid = fields[1]
    local me = OMQ:GetSelf()
    if not guid or guid == "" or (me and guid == me.guid) then return end
    local u = OMQ.users[guid]
    if not u then return end
    local v = {}
    for i, k in ipairs(KEYS) do v[k] = tonumber(fields[i + 1]) end
    for _, k in ipairs(KEYS2) do v[k] = u.life and u.life[k] or nil end    -- sent by the second message
    u.life = v
    -- remember for the days this player is offline
    OMQDB.people = OMQDB.people or {}
    OMQDB.people[guid] = { name = u.name, class = u.class, life = v, seen = time() }
end
OMQ:RegisterMessage("L", handle)

local function handle2(fields)
    local guid = fields[1]
    local me = OMQ:GetSelf()
    if not guid or guid == "" or (me and guid == me.guid) then return end
    local u = OMQ.users[guid]
    if not u then return end
    u.life = u.life or {}
    for i, k in ipairs(KEYS2) do u.life[k] = tonumber(fields[i + 1]) end
    OMQDB.people = OMQDB.people or {}
    local p = OMQDB.people[guid]
    if p then p.life = u.life else
        OMQDB.people[guid] = { name = u.name, class = u.class, life = u.life, seen = time() }
    end
end
OMQ:RegisterMessage("L2", handle2)

----------------------------------------------------------------------
-- Time spent together (decision 114): OMQDB.together[myGuid][otherGuid] = seconds
-- Counted every TOGETHER_TICK seconds for each addon user in my group while I am
-- not AFK. Decides which four earlier mates the window shows without a group.
----------------------------------------------------------------------
local TOGETHER_TICK = 60
local MAX_SHOWN = 5          -- me + 4; more than 5 users in a group are not supported (cut)

local function groupGuids()
    local set = {}
    local function add(unit)
        if UnitExists and not UnitExists(unit) then return end
        local g = UnitGUID(unit)
        if g then set[g] = true end
    end
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do add("raid" .. i) end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do add("party" .. i) end
    end
    return set
end

-- addon users that are in my group right now (without me)
local function groupUsers()
    local me = OMQ:GetSelf()
    local set = groupGuids()
    local list = {}
    for guid in pairs(set) do
        local u = OMQ.users and OMQ.users[guid]
        if u and OMQ:IsOnline(u) and not (me and guid == me.guid) then list[#list + 1] = guid end
    end
    return list
end

local function togetherTick()
    local me = OMQ:GetSelf()
    if not me or (UnitIsAFK and UnitIsAFK("player")) then return end
    local guids = groupUsers()
    if #guids == 0 then return end
    OMQDB.together = OMQDB.together or {}
    local mine = OMQDB.together[me.guid] or {}
    OMQDB.together[me.guid] = mine
    OMQDB.people = OMQDB.people or {}
    for _, guid in ipairs(guids) do
        mine[guid] = (mine[guid] or 0) + TOGETHER_TICK
        local u = OMQ.users[guid]
        local p = OMQDB.people[guid]
        if not p then
            OMQDB.people[guid] = { name = u.name, class = u.class, life = u.life or {}, seen = time() }
        else
            p.seen = time()
        end
    end
end

function L:TogetherTick() togetherTick() end

-- People for the window.
-- In a group with addon users: exactly that group (me first, cut at 5).
-- Otherwise: me plus the four earlier mates I spent the most time with (snapshots).
function L:GetPeople()
    local people = {}
    local me = OMQ:GetSelf()
    if not me then return people end
    people[1] = { guid = me.guid, name = me.name, class = me.class, isSelf = true, online = true, values = self:GetValues() }

    local guids = groupUsers()
    if #guids > 0 then
        local others = {}
        for _, guid in ipairs(guids) do
            local u = OMQ.users[guid]
            others[#others + 1] = { guid = guid, name = u.name, class = u.class, online = true,
                                    values = u.life or (OMQDB.people and OMQDB.people[guid] and OMQDB.people[guid].life) or {} }
        end
        table.sort(others, function(a, b) return (a.name or "") < (b.name or "") end)
        for _, p in ipairs(others) do
            if #people >= MAX_SHOWN then break end
            people[#people + 1] = p
        end
        return people
    end

    local mine = OMQDB.together and OMQDB.together[me.guid] or {}
    local mates = {}
    for guid, secs in pairs(mine) do
        local p = OMQDB.people and OMQDB.people[guid]
        if p and guid ~= me.guid then
            mates[#mates + 1] = { guid = guid, name = p.name, class = p.class, online = false,
                                  values = p.life or {}, seen = p.seen or 0, together = secs }
        end
    end
    table.sort(mates, function(a, b)
        if a.together ~= b.together then return a.together > b.together end
        return (a.name or "") < (b.name or "")
    end)
    for _, p in ipairs(mates) do
        if #people >= MAX_SHOWN then break end
        people[#people + 1] = p
    end
    return people
end

OMQ:On("READY", function()
    loadCachedIds()
    scanStatistics(true)          -- in the background, long before the first hover
    C_Timer.NewTicker(SEND_INTERVAL, function() pcall(L.Send, L) end)
    C_Timer.NewTicker(TOGETHER_TICK, function() pcall(togetherTick) end)
end)
OMQ:On("USER_JOINED", function() pcall(L.Send, L) end)

OMQ:RegisterCommand("lifetime", function(arg)
    if arg == "scan" then
        L:RescanStatistics()
        local n = 0
        for k, id in pairs(statIds) do n = n + 1; print("  " .. k .. " = statistic " .. tostring(id)) end
        OMQ:Print(n .. " statistics found by name")
        return
    end
    if OMQ.LifetimeWindow then OMQ.LifetimeWindow:Toggle() end
end, "open the lifetime window; /omq lifetime scan lists the statistics found")
