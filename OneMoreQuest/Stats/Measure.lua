-- One More Quest: Measure
-- Measures the player's own session statistics (section 3.3, adapted to what
-- WoW Forever allows, section 13). Values are saved in OMQDB.sessions[guid] so a reload
-- does not lose them. Health numbers are secret on Forever and never used (fall damage: decision 396).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local MIN_SESSION = 600             -- seconds; shorter sessions are not kept
local SESSION_RESET = 3600          -- decision 16 (simplified: own inactivity)
local SAMPLE_INTERVAL = 0.25        -- seconds between position / low-health samples
local MAX_YARDS_PER_SAMPLE = 30     -- larger jumps are teleports, not walking
local CAST_WINDOW = 1.0             -- group hit attribution window after own spell

local M = {}
OMQ.Measure = M

local s                              -- shorthand for this character's session

----------------------------------------------------------------------
-- Session handling
----------------------------------------------------------------------
local function newSession()
    local level = UnitLevel("player") or 1
    local xp, xpMax = UnitXP("player") or 0, UnitXPMax("player") or 1
    return {
        start = time(), lastActive = time(),
        startLevelValue = level + (xpMax > 0 and xp / xpMax or 0),
        startLevel = level,
        xpGained = 0, goldGained = 0, yards = 0,
        yardsFollow = 0,                 -- the part of the yards walked while following a group member (decision 332)
        fallDmg = 0,                     -- own fall damage, see the falling section
        xpQuest = 0, xpDisc = 0,         -- XP by source; the rest of xpGained counts as kills (decision 116)
        kills = 0, deaths = 0, nearDeaths = 0,
        dmgMine = 0, dmgTotal = 0,          -- damage of me / of me plus the addon users, summed fight by fight
        quests = 0, fights = 0, bestHeal = 0, needRolls = 0, greedRolls = 0,
        gamble = 0, betsWon = 0,         -- Bet Check: net copper won or lost, bets won (decision 167)
        statBase = {},                   -- game statistics at session start (decision 120)
        biggestHit = 0, hitApprox = false,
        foodSeconds = 0, onlineSeconds = 0,
        members = {},                    -- guid -> { name, class } of addon users met
    }
end

-- Sessions are kept per character (by GUID), so another character on the same
-- account starts with a fresh session.
-- Finished sessions are never deleted: they go to OMQDB.history[guid] (a list,
-- oldest first) so a later version can show the whole journey. One record is
-- about 0.4 KB in the saved file, so 1000 sessions are roughly 0.4 MB.
local function archive(old)
    local guid = UnitGUID("player")
    if not (guid and old) then return end
    -- anything under 10 minutes is not a session
    if ((old.lastActive or 0) - (old.start or 0)) < MIN_SESSION then return end
    old.endTime = old.lastActive
    OMQDB.history = OMQDB.history or {}
    OMQDB.history[guid] = OMQDB.history[guid] or {}
    table.insert(OMQDB.history[guid], old)
end

local function store(session)
    local guid = UnitGUID("player")
    OMQDB.sessions = OMQDB.sessions or {}
    if guid then
        local old = OMQDB.sessions[guid]
        if old and old ~= session then archive(old) end
        OMQDB.sessions[guid] = session
        -- remember who this GUID is, for the journey view
        OMQDB.characters = OMQDB.characters or {}
        local me = OMQ:GetSelf()
        OMQDB.characters[guid] = { name = UnitName("player"), class = select(2, UnitClass("player")) }
    end
    return session
end

local function load()
    OMQDB.session = nil                          -- old shared session (before 0.1.3)
    local guid = UnitGUID("player")
    return guid and OMQDB.sessions and OMQDB.sessions[guid]
end

function M:ResetSession()
    s = store(newSession())
    -- decision 135: a new session starts with the dads in my group only, and for the first
    -- minutes after a reset those who leave the group disappear from the session view
    s.freshAt = time()
    for guid, u in pairs(OMQ.users or {}) do
        if OMQ:IsOnline(u) then s.members[guid] = { name = u.name, class = u.class } end
    end
    -- the game's own counters start from what they say right now
    local stats = OMQ.Lifetime and OMQ.Lifetime.GetStatValues and OMQ.Lifetime:GetStatValues() or {}
    for _, k in ipairs({ "falld", "drownd", "lava", "aucp", "aucb", "need", "greed" }) do
        if type(stats[k]) == "number" then s.statBase[k] = stats[k] end
    end
    self:SnapshotXP()
    OMQ:Fire("SESSION_RESET")
end

-- Raw session table (Bet Check reads yards, near deaths, falls and damage from it)
function M:Session() return s end

-- Remember XP so the next update can be turned into a difference.
function M:SnapshotXP()
    self.lastLevel = UnitLevel("player") or 1
    self.lastXP = UnitXP("player") or 0
    self.lastXPMax = UnitXPMax("player") or 1
end

----------------------------------------------------------------------
-- Value access (numbers, or nil = no data)
----------------------------------------------------------------------
function M:GetValues()
    if not s then return {} end
    local v = {}
    local level = UnitLevel("player") or 1
    local xp, xpMax = UnitXP("player") or 0, UnitXPMax("player") or 1
    local current = level + (xpMax > 0 and xp / xpMax or 0)
    local hours = math.max(time() - s.start, 60) / 3600
    v.xph = s.xpGained / hours
    v.lvlp = current - s.startLevelValue
    v.lvl = current
    -- time until the next level at the session's XP per hour (decision 194)
    if level < 60 and v.xph > 0 then v.nextlvl = (xpMax - xp) / v.xph * 3600 end
    v.yards = s.yards
    v.yfollow = s.yardsFollow or 0
    v.gold = s.goldGained
    v.curgold = GetMoney and GetMoney() or nil
    v.dmg = (s.dmgTotal or 0) > 0 and (s.dmgMine / s.dmgTotal * 100) or self.damageShare
    v.kb = s.kills
    v.hit = s.biggestHit > 0 and s.biggestHit or nil
    v.hitApprox = s.hitApprox
    v.deaths = s.deaths
    v.near = s.nearDeaths
    v.food = s.onlineSeconds > 0 and (s.foodSeconds / s.onlineSeconds * 100) or nil
    -- decision 120: the same rows as the lifetime window
    v.ptime = time() - s.start
    v.xp = s.xpGained
    v.xpquest = s.xpQuest
    v.xpdisc = s.xpDisc
    v.xpkill = math.max(0, s.xpGained - (s.xpQuest or 0) - (s.xpDisc or 0))
    v.quests = s.quests
    v.fights = s.fights
    v.heal = (s.bestHeal or 0) > 0 and s.bestHeal or nil
    v.fallx = s.fallDmg
    v.need = s.needRolls
    v.greed = s.greedRolls
    v.gamble = s.gamble or 0
    v.betswon = s.betsWon or 0
    -- values the game counts itself: the difference to the start of this session
    local stats = OMQ.Lifetime and OMQ.Lifetime.GetStatValues and OMQ.Lifetime:GetStatValues() or {}
    s.statBase = s.statBase or {}
    for _, k in ipairs({ "falld", "drownd", "lava", "aucp", "aucb", "need", "greed" }) do
        local cur = stats[k]
        if type(cur) == "number" then
            if s.statBase[k] == nil then s.statBase[k] = cur end
            v[k] = math.max(0, cur - s.statBase[k])
            -- my own click count is instant, the game's counter may lag: take the larger
            if k == "need" then v[k] = math.max(v[k], s.needRolls or 0)
            elseif k == "greed" then v[k] = math.max(v[k], s.greedRolls or 0) end
        end
    end
    return v
end

function M:GetSessionInfo()
    if not s then return nil end
    return { elapsed = time() - s.start, startLevel = s.startLevel,
             level = UnitLevel("player") or s.startLevel }
end

----------------------------------------------------------------------
-- XP and gold
----------------------------------------------------------------------
local function onXP()
    local level, xp, xpMax = UnitLevel("player") or 1, UnitXP("player") or 0, UnitXPMax("player") or 1
    if M.lastXP then
        if level > M.lastLevel then
            -- level up: rest of the old level plus what we have in the new one
            s.xpGained = s.xpGained + math.max(M.lastXPMax - M.lastXP, 0) + xp
        else
            s.xpGained = s.xpGained + math.max(xp - M.lastXP, 0)
        end
    end
    M.lastLevel, M.lastXP, M.lastXPMax = level, xp, xpMax
    s.lastActive = time()
end

-- XP from a turned in quest (the reward the game reports)
local function onQuestTurnedIn(questID, xpReward)
    s.quests = (s.quests or 0) + 1
    if s.xpQuest and type(xpReward) == "number" and not (issecretvalue and issecretvalue(xpReward)) and xpReward > 0 then
        s.xpQuest = s.xpQuest + xpReward
    end
end

-- XP from discovering a zone: the system message "Discovered %s: %d experience gained",
-- turned into a pattern from the game's own (translated) text. It arrives as a chat
-- system message and as an info message on screen; the same text within 2 s counts once.
local discoveryPattern, discoveryIndex
local lastDiscovery, lastDiscoveryAt = nil, -math.huge
M.recentTexts = {}           -- last system texts with a number, for /omq xp

-- Returns the pattern and which capture holds the number. Placeholders are swapped in
-- one pass (so a replacement is never replaced again); positional forms like
-- "%1$s entdeckt: %2$d Erfahrung" work as well as "Discovered %s: %d experience".
local function buildDiscoveryPattern()
    local fmt = _G.ERR_ZONE_EXPLORED_XP
    if type(fmt) ~= "string" then return false end
    local esc = fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    local kinds = {}
    esc = esc:gsub("%%(%d?)%%?%$?([sd])", function(_, kind)
        kinds[#kinds + 1] = kind
        return kind == "d" and "\1" or "\2"
    end)
    esc = esc:gsub("\1", "(%%d+)"):gsub("\2", "(.+)")
    local numberIndex = 1
    for i, k in ipairs(kinds) do if k == "d" then numberIndex = i; break end end
    return esc, numberIndex
end

local function countDiscovery(text)
    if not s.xpDisc or type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return end
    if text:find("%d") then
        local r = M.recentTexts
        r[#r + 1] = text:sub(1, 120)
        if #r > 8 then table.remove(r, 1) end
    end
    if discoveryPattern == nil then discoveryPattern, discoveryIndex = buildDiscoveryPattern() end
    if not discoveryPattern then return end
    local caps = { text:match(discoveryPattern) }
    local xp = tonumber(caps[discoveryIndex or 1])
    if not (xp and xp > 0) then return end
    if text == lastDiscovery and GetTime() - lastDiscoveryAt < 2 then return end
    lastDiscovery, lastDiscoveryAt = text, GetTime()
    s.xpDisc = s.xpDisc + xp
end

local function onSystemMessage(text) countDiscovery(text) end
local function onInfoMessage(_, text) countDiscovery(text) end

local tradeOpen, tradeClosedAt = false, 0
local lastMoney
local function onMoney()
    local money = GetMoney()
    if lastMoney and money > lastMoney then
        local ignoring = tradeOpen or (GetTime() - tradeClosedAt) < 1.5
        if not ignoring then s.goldGained = s.goldGained + (money - lastMoney) end
    end
    lastMoney = money
    s.lastActive = time()
end

----------------------------------------------------------------------
-- Combat: killing blows, deaths, biggest hit
----------------------------------------------------------------------
local function isNumber(x)
    if issecretvalue and issecretvalue(x) then return false end
    return type(x) == "number"
end

local function onPartyKill(killer)
    local ok, mine = pcall(function() return killer == UnitGUID("player") end)
    if ok and mine then s.kills = s.kills + 1 end
end

local lowHealthSeen = false
local function onDeath()
    s.deaths = s.deaths + 1
    lowHealthSeen = false             -- death ends the near-death attempt
end

local lastOwnCast = -100
local function onOwnCast(unit)
    if unit == "player" then lastOwnCast = GetTime() end
end

-- UNIT_COMBAT on the target gives readable numbers, but the damage of every
-- player. Alone the maximum is exact. In a group only hits right after our own
-- spell count and the value is marked approximate.
local landed          -- { at = time of landing, hp0 = health before the fall (or nil) }
M.fallInfo = { events = 0, readable = 0, secret = 0, byHealth = 0, healthReadable = nil, lastAmount = nil,
                fallingAt = nil,    -- fallingAt: the last moment I was seen falling (decision 224)
                estimated = 0, lastHeight = nil, lastEstimate = nil }   -- decision 396

----------------------------------------------------------------------
-- Fall damage from the fall time (decision 396). Where the hit amount and the health are secret
-- (retail, and maybe Forever), the damage is computed the way the game does it: the height fallen
-- from the fall time (gravity 19.29 yd/s^2, at most 60 yd/s, a jump starts 7.96 yd/s upwards), then
-- damage = (0.018 x height - 0.2426) x max health (UnitHealthMax is readable). It only counts when the
-- game signals a hit or a health change right after the landing (no damage with slow fall).
----------------------------------------------------------------------
local GRAVITY, TERMINAL, JUMP_SPEED, SAFE_HEIGHT = 19.29, 60, 7.96, 14.57
local fallStartAt, fallJumped, lastJumpAt = nil, false, -100

-- yards fallen below the start point after t seconds of falling
function M.FallHeight(t, jumped)
    t = tonumber(t) or 0
    if t <= 0 then return 0 end
    local v0 = jumped and JUMP_SPEED or 0              -- upwards
    local tUp = v0 / GRAVITY
    local rise = v0 * tUp / 2
    local tDown = t - tUp
    if tDown <= 0 then return 0 end
    local tTerm = TERMINAL / GRAVITY
    local down
    if tDown <= tTerm then down = GRAVITY * tDown * tDown / 2
    else down = TERMINAL * tTerm / 2 + TERMINAL * (tDown - tTerm) end
    return math.max(0, down - rise)
end

-- the damage of a fall of this height for this max health (0: a safe fall)
function M.FallDamage(height, maxHp)
    if not (height and maxHp and height >= SAFE_HEIGHT) then return 0 end
    local perc = 0.018 * height - 0.2426
    if perc <= 0 then return 0 end
    return math.floor(math.min(perc, 0.99) * maxHp + 0.5)
end

local function onJump() lastJumpAt = GetTime() end
if hooksecurefunc and _G.JumpOrAscendStart then pcall(hooksecurefunc, "JumpOrAscendStart", onJump) end

-- the game's hit or health event can come in the same frame as the landing, before the addon sees
-- that I stopped falling: the last one is kept and counts when it came up to 0.3 s before the landing
local lastHitAt, lastHit = -100, nil
local HIT_BEFORE = 0.3
local hpBefore
local countFall                      -- defined below

-- every frame (decision 396; before, every 0.25 s): fall start, landing, fall time
local function trackFall()
    local falling = IsFalling and IsFalling() and true or false
    if falling then M.fallInfo.fallingAt = GetTime() end
    if falling and not fallStartAt then
        fallStartAt = GetTime()
        fallJumped = GetTime() - lastJumpAt <= 0.3
        local hp = UnitHealth and UnitHealth("player")
        hpBefore = isNumber(hp) and hp or nil
    elseif not falling and fallStartAt then
        local t = GetTime() - fallStartAt
        fallStartAt = nil
        M.fallInfo.lastHeight = M.FallHeight(t, fallJumped)
        M.fallInfo.lastFallTime = t
        landed = { at = GetTime(), hp0 = hpBefore, height = M.fallInfo.lastHeight }
        if GetTime() - lastHitAt <= HIT_BEFORE then
            landed.sawHit = true
            local h = lastHit
            lastHitAt, lastHit = -100, nil
            if h and GetTime() - h.at > HIT_BEFORE then h = nil end
            if h and s.fallDmg and not (InCombatLockdown and InCombatLockdown()) then
                M.fallInfo.events = M.fallInfo.events + 1
                if isNumber(h.amount) then countFall(h.amount, "readable")
                else M.fallInfo.secret = M.fallInfo.secret + 1; M.fallInfo.lastAmount = nil end
            end
        end
    end
end
M._trackFall = trackFall

-- a health change of mine right after the landing is the sign of fall damage, even when secret
local healthEvents = CreateFrame("Frame")
if healthEvents.RegisterUnitEvent then pcall(healthEvents.RegisterUnitEvent, healthEvents, "UNIT_HEALTH", "player") end
healthEvents:SetScript("OnEvent", function()
    if landed and GetTime() - landed.at <= 1.0 then landed.sawHit = true
    elseif not landed then lastHitAt = GetTime() end
end)

countFall = function(amount, how)
    s.fallDmg = (s.fallDmg or 0) + amount
    M.fallInfo[how] = M.fallInfo[how] + 1
    M.fallInfo.lastAmount = amount
    landed = nil
end

-- Fights initiated (decision 215): who brings the group into combat is decided by Stats/Pull.lua;
-- it calls this for me when I was the first one in combat.
local lastHurt, lastAttack = -100, -100
function M:CountFight()
    if not s then return end
    s.fights = (s.fights or 0) + 1
end

-- Biggest heal (approximate): a heal on me or my target right after my own spell.
local function countHeal(amount)
    if not isNumber(amount) then return end
    if GetTime() - lastOwnCast > CAST_WINDOW then return end
    if amount > (s.bestHeal or 0) then s.bestHeal = amount end
end

local function onUnitCombat(unit, action, descriptor, amount)
    if action == "HEAL" and (unit == "player" or unit == "target") then
        countHeal(amount)
        return
    end
    if unit == "player" and action ~= "HEAL" then lastHurt = GetTime() end
    if unit == "player" then
        -- first hit right after landing, out of combat: fall damage
        if action == "WOUND" and not landed then
            -- the hit came before the addon saw the landing (decision 396): trackFall counts it
            lastHitAt, lastHit = GetTime(), { amount = amount, at = GetTime() }
        end
        if action == "WOUND" and landed and not landed.counted and s.fallDmg and GetTime() - landed.at <= 1.5
            and not (InCombatLockdown and InCombatLockdown()) then
            M.fallInfo.events = M.fallInfo.events + 1
            if isNumber(amount) then countFall(amount, "readable")
            else M.fallInfo.secret = M.fallInfo.secret + 1; M.fallInfo.lastAmount = nil; landed.sawHit = true end
        end
        return
    end
    if unit ~= "target" or action ~= "WOUND" or not isNumber(amount) then return end
    if not UnitCanAttack("player", "target") then return end
    local grouped = IsInGroup and IsInGroup()
    if grouped then
        if GetTime() - lastOwnCast > CAST_WINDOW then return end
        s.hitApprox = true
    end
    if amount > s.biggestHit then s.biggestHit = amount end
end

-- Damage share from Blizzard's damage meter (only damage dealt while grouped).
function M:UpdateDamageShare()
    self.damageShare = nil
    if not (IsInGroup and IsInGroup()) then return end
    if not (C_DamageMeter and Enum and Enum.DamageMeterType and Enum.DamageMeterSessionType) then return end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageDone)
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then return end
    local me = OMQ:GetSelf()
    if not me then return end
    local members = { [me.guid] = true }
    for guid in pairs(OMQ.users) do members[guid] = true end
    local mine, total = 0, 0
    for _, src in ipairs(session.combatSources) do
        local guid = src.sourceGUID or src.GUID or src.guid
        local amount = src.totalAmount
        if guid and members[guid] and isNumber(amount) then
            total = total + amount
            if guid == me.guid then mine = amount end
        end
    end
    if total > 0 then self.damageShare = mine / total * 100 end
end

-- Damage share fight by fight: after every fight the finished fight is read from the
-- damage meter and added to two counters in the session, so a reset of the meter loses
-- nothing. Only me and the addon users are counted (also fights alone).
local seenFights = {}            -- fight ids that existed when the addon started (never counted)
-- decision 229: a fight is read again for a while after it ended; the damage meter may still be
-- adding to it (another dad still fighting, late ticks) or its numbers may not be readable yet.
-- counted[id] = { mine, total, at } what was added so far; only the difference is added again.
local counted = {}
local RECOUNT_FOR = 30           -- seconds a fight is read again

local function listFights()
    if not (C_DamageMeter and C_DamageMeter.GetAvailableCombatSessions) then return nil end
    local ok, list = pcall(C_DamageMeter.GetAvailableCombatSessions)
    if not ok or type(list) ~= "table" then return nil end
    return list
end

local function fightDamage(id)
    local dtype = Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone
    if not (C_DamageMeter.GetCombatSessionFromID and dtype) then return nil end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromID, id, dtype)
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then return nil end
    local me = OMQ:GetSelf()
    if not me then return nil end
    local members = { [me.guid] = true }
    for guid in pairs(OMQ.users or {}) do members[guid] = true end
    local mine, total = 0, 0
    for _, src in ipairs(session.combatSources) do
        local guid = src.sourceGUID or src.GUID or src.guid
        local amount = src.totalAmount
        if guid and not (issecretvalue and issecretvalue(guid)) and members[guid] then
            if not isNumber(amount) then return nil end      -- unreadable: try again later
            total = total + amount
            if guid == me.guid then mine = amount end
        end
    end
    return mine, total
end

function M:CollectFights()
    local list = listFights()
    if not list then return 0 end
    local added = 0
    local t = GetTime()
    for _, f in ipairs(list) do
        local id = type(f) == "table" and (f.sessionID or f.id) or f
        local c = id ~= nil and counted[id]
        if id ~= nil and not seenFights[id] and not (c and t - c.at > RECOUNT_FOR) then
            local mine, total = fightDamage(id)
            if mine then
                c = c or { mine = 0, total = 0, at = t }
                counted[id] = c
                local dm, dt = mine - c.mine, total - c.total
                if dm > 0 or dt > 0 then
                    s.dmgMine = (s.dmgMine or 0) + math.max(0, dm)
                    s.dmgTotal = (s.dmgTotal or 0) + math.max(0, dt)
                    c.mine, c.total = math.max(c.mine, mine), math.max(c.total, total)
                    added = added + 1
                end
            end
        end
    end
    return added
end

-- what the damage meter shows for the newest fight (decision 229), for the bet note and /omq dmg
function M:FightDiag()
    local list = listFights()
    if not list then return "damage meter API missing" end
    local f = list[#list]
    local id = type(f) == "table" and (f.sessionID or f.id) or f
    if id == nil then return "no fight in the damage meter" end
    local dtype = Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromID, id, dtype)
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then
        return "newest fight " .. tostring(id) .. " not readable"
    end
    local me = OMQ:GetSelf()
    local found, secretGuid, secretAmount = "not listed", 0, 0
    for _, src in ipairs(session.combatSources) do
        local guid = src.sourceGUID or src.GUID or src.guid
        if issecretvalue and issecretvalue(guid) then secretGuid = secretGuid + 1
        elseif me and guid == me.guid then
            found = isNumber(src.totalAmount) and tostring(src.totalAmount) or "secret"
        end
        if not isNumber(src.totalAmount) then secretAmount = secretAmount + 1 end
    end
    local c = counted[id]
    return string.format("fights %d, newest %s: %d sources, me %s, secret names %d, secret amounts %d, counted %s",
        #list, tostring(id), #session.combatSources, found, secretGuid, secretAmount, c and tostring(c.mine) or "no")
end

-- fights that exist when the addon starts are not counted
local function markKnownFights()
    for _, f in ipairs(listFights() or {}) do
        local id = type(f) == "table" and (f.sessionID or f.id) or f
        if id ~= nil then seenFights[id] = true end
    end
end

----------------------------------------------------------------------
-- Sampling: position, near deaths, food buff
----------------------------------------------------------------------
-- falling state: remember health when the fall starts, note the landing, and when the
-- hit amount was unreadable use the health lost (only if both values are readable)
-- (the fall start and the landing are seen every frame by trackFall, decision 396)
local function sampleFall()
    if landed and GetTime() - landed.at > 1.0 then
        local l = landed
        landed = nil
        if s.fallDmg and l.hp0 and not (InCombatLockdown and InCombatLockdown())
            and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then
            local hp = UnitHealth and UnitHealth("player")
            M.fallInfo.healthReadable = isNumber(hp)
            if isNumber(hp) and l.hp0 - hp > 0 then
                -- the health may have regenerated a bit; a lower bound of the damage
                M.fallInfo.events = M.fallInfo.events + 1
                M.fallInfo.lastAmount = l.hp0 - hp            -- the bets read this one (decision 224)
                s.fallDmg = s.fallDmg + (l.hp0 - hp)
                M.fallInfo.byHealth = M.fallInfo.byHealth + 1
            end
        end
        -- no readable amount and no readable health: computed from the fall time (decision 396)
        if s.fallDmg and l.sawHit and not l.counted and not (l.hp0 and isNumber(UnitHealth and UnitHealth("player")))
            and not (InCombatLockdown and InCombatLockdown()) and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then
            local maxHp = UnitHealthMax and UnitHealthMax("player")
            local est = isNumber(maxHp) and M.FallDamage(l.height, maxHp) or 0
            M.fallInfo.lastEstimate = est
            if est > 0 then
                M.fallInfo.events = M.fallInfo.events + 1
                M.fallInfo.lastAmount = est                   -- the bets read this one
                M.fallInfo.estimated = M.fallInfo.estimated + 1
                s.fallDmg = s.fallDmg + est
            end
        end
    elseif landed then
        local hp = UnitHealth and UnitHealth("player")
        M.fallInfo.healthReadable = isNumber(hp)
    end
end

-- following a group member (decision 332): the game says when the automatic follow starts and stops
local following = false
local followEvents = CreateFrame("Frame")
for _, e in ipairs({ "AUTOFOLLOW_BEGIN", "AUTOFOLLOW_END" }) do pcall(followEvents.RegisterEvent, followEvents, e) end
followEvents:SetScript("OnEvent", function(_, event) following = (event == "AUTOFOLLOW_BEGIN") end)
function M:IsFollowing() return following end

local lastX, lastY, lastInstance
local function sampleDistance()
    if not UnitPosition then return end
    local y, x, _, instance = UnitPosition("player")
    if not (isNumber(x) and isNumber(y)) then lastX = nil; return end
    local onFoot = not (IsMounted and IsMounted()) and not (IsFlying and IsFlying())
        and not (UnitOnTaxi and UnitOnTaxi("player"))
        and not (IsFalling and IsFalling())
    if lastX and instance == lastInstance and onFoot then
        local d = math.sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2)
        if d <= MAX_YARDS_PER_SAMPLE then
            s.yards = s.yards + d
            -- the yards of a follow count in the total as well (decision 332)
            if following then s.yardsFollow = (s.yardsFollow or 0) + d end
        end
    end
    lastX, lastY, lastInstance = x, y, instance
end

local function sampleLowHealth()
    local f = _G.LowHealthFrame
    if not f then return end
    local shown = f:IsShown() and true or false
    if shown then
        lowHealthSeen = true
    elseif lowHealthSeen then
        lowHealthSeen = false
        if not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then
            s.nearDeaths = s.nearDeaths + 1
        end
    end
end

local wellFedName
local hasFood = false
local function sampleFood()
    s.onlineSeconds = s.onlineSeconds + 1
    s.endLevel = UnitLevel("player") or s.endLevel
    -- Aura names can be unreadable in combat; keep the last known state then.
    if not InCombatLockdown() and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        wellFedName = wellFedName
            or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(19705))
            or (GetSpellInfo and GetSpellInfo(19705))
            or "Well Fed"
        local found = false
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            local ok, match = pcall(function() return aura.name == wellFedName end)
            if ok and match then found = true; break end
        end
        hasFood = found
    end
    if hasFood then s.foodSeconds = s.foodSeconds + 1 end
    s.lastActive = time()
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local frame = CreateFrame("Frame")
-- Joining a group ends the session and starts a new one (decision 129): everybody
-- starts with an empty sheet. Reloads and group changes while grouped keep it.
-- Decision 232: the session remembers whether I was grouped (s.inGroup). After a login the game
-- reports the group only a moment later; a relog into the same group (another character in
-- between, mail checked) is no "joining" then. The session timeout still applies.
local wasGrouped = false
local LOGIN_GRACE = 20           -- seconds after login in which the group may still show up
local function grouped() return (IsInGroup and IsInGroup()) and true or false end
local function onRosterUpdate()
    local now = grouped()
    if now and not wasGrouped then
        M:ResetSession()
    end
    wasGrouped = now
    if s then s.inGroup = now end
end
M._onRosterUpdate = onRosterUpdate

local events = {
    GROUP_ROSTER_UPDATE = onRosterUpdate,
    PLAYER_XP_UPDATE = onXP,
    QUEST_TURNED_IN = onQuestTurnedIn,
    CHAT_MSG_SYSTEM = onSystemMessage,
    UI_INFO_MESSAGE = onInfoMessage,
    PLAYER_MONEY = onMoney,
    PARTY_KILL = onPartyKill,
    PLAYER_DEAD = onDeath,
    PLAYER_REGEN_ENABLED = function()
        -- give the damage meter a moment to close the fight
        -- and read it again a few times (decision 229)
        for _, d in ipairs({ 1.5, 4, 8, 15 }) do
            C_Timer.After(d, function() if s then pcall(M.CollectFights, M) end end)
        end
    end,
    PLAYER_ENTER_COMBAT = function() lastAttack = GetTime() end,
    UNIT_COMBAT = onUnitCombat,
    UNIT_SPELLCAST_SUCCEEDED = onOwnCast,
    TRADE_SHOW = function() tradeOpen = true end,
    TRADE_CLOSED = function() tradeOpen = false; tradeClosedAt = GetTime() end,
}
for e in pairs(events) do frame:RegisterEvent(e) end
frame:SetScript("OnEvent", function(_, event, ...)
    if not s then return end
    local ok, err = pcall(events[event], ...)
    if not ok then OMQ:Error(event, err) end
end)

local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if not s then return end
    pcall(trackFall)
    acc = acc + elapsed
    if acc < SAMPLE_INTERVAL then return end
    acc = 0
    pcall(sampleDistance)
    pcall(sampleFall)
    pcall(sampleLowHealth)
end)

-- Own loot roll choices: the game's RollOnLoot(rollID, rollType) is called for every
-- click on a loot roll button (1 = need, 2 = greed). Locale independent.
local function onRoll(_, rollType)
    if not s then return end
    if rollType == 1 then s.needRolls = (s.needRolls or 0) + 1
    elseif rollType == 2 then s.greedRolls = (s.greedRolls or 0) + 1 end
end
M.OnRoll = onRoll
if hooksecurefunc then
    if _G.RollOnLoot then hooksecurefunc("RollOnLoot", function(...) pcall(onRoll, ...) end) end
    if C_Loot and C_Loot.RollOnLoot then hooksecurefunc(C_Loot, "RollOnLoot", function(...) pcall(onRoll, ...) end) end
end

OMQ:On("READY", function()
    local old = load()
    if old and (time() - (old.lastActive or 0)) < SESSION_RESET then
        s = old
        -- a session from before these counters existed: start them now
        if s.xpQuest == nil then s.xpQuest = 0 end
        if s.xpDisc == nil then s.xpDisc = 0 end
        if s.fallDmg == nil then s.fallDmg = 0 end
        if s.quests == nil then s.quests = 0 end
        if s.dmgMine == nil then s.dmgMine = 0 end
        if s.dmgTotal == nil then s.dmgTotal = 0 end
        if s.fights == nil then s.fights = 0 end
        if s.bestHeal == nil then s.bestHeal = 0 end
        if s.needRolls == nil then s.needRolls = 0 end
        if s.greedRolls == nil then s.greedRolls = 0 end
        if s.statBase == nil then s.statBase = {} end
        if s.gamble == nil then s.gamble = 0 end
        if s.betsWon == nil then s.betsWon = 0 end
    else
        s = store(newSession())
    end
    M:SnapshotXP()
    -- grouped before the logout (same session): the group coming back is not a new group
    wasGrouped = grouped() or (s.inGroup == true)
    s.inGroup = wasGrouped
    if C_Timer.After then
        C_Timer.After(LOGIN_GRACE, function()
            -- the group did not come back: from now on a join is a join again
            if not grouped() then wasGrouped = false; if s then s.inGroup = false end end
        end)
    end
    pcall(markKnownFights)
    lastMoney = GetMoney()
    C_Timer.NewTicker(1, function() pcall(sampleFood) end)
    C_Timer.NewTicker(5, function() pcall(M.UpdateDamageShare, M) end)
end)

OMQ:RegisterCommand("session", function(arg)
    if arg == "reset" then
        M:ResetSession()
        OMQ:Print("session reset")
        return
    end
    local v = M:GetValues()
    OMQ:Print("my session values:")
    for _, k in ipairs({ "xph", "lvlp", "lvl", "yards", "gold", "curgold", "dmg", "kb", "hit", "deaths", "near", "food",
        "ptime", "xp", "xpkill", "xpquest", "xpdisc", "quests", "fights", "heal", "fallx", "falld", "drownd", "lava", "aucp", "aucb", "need", "greed", "yfollow" }) do
        print(string.format("  %s = %s", k, v[k] ~= nil and string.format("%.2f", v[k]) or "no data"))
    end
end, "show own session values; /omq session reset starts a new session")


OMQ:RegisterCommand("history", function()
    local sessions, bytes = 0, 0
    for guid, list in pairs(OMQDB.history or {}) do
        local c = OMQDB.characters and OMQDB.characters[guid]
        print(string.format("  %s: %d finished sessions", c and c.name or guid, #list))
        sessions = sessions + #list
    end
    OMQ:Print(string.format("%d finished sessions kept (about %.1f KB in the saved file)", sessions, sessions * 0.4))
end, "number of saved sessions")


-- Group members who also run the addon are saved with the session.
OMQ:On("USER_UPDATED", function(guid)
    if not s then return end
    local u = OMQ.users and OMQ.users[guid]
    if not u then return end
    s.members = s.members or {}
    local m = s.members[guid]
    if not OMQ:InGroup(guid) then return end
    if not m or m.name ~= u.name then
        s.members[guid] = { name = u.name, class = u.class }
    end
end)

-- Session members for the session view. Returns the member table, and whether the
-- "fresh" rule applies (first 5 minutes after a reset while another dad is in the group):
-- then only the people in my group count and the others are forgotten (decision 135).
local FRESH_WINDOW = 300
function M:SessionMembers(othersInGroup)
    if not s then return {}, false end
    s.members = s.members or {}
    if s.freshAt and (not othersInGroup or time() - s.freshAt >= FRESH_WINDOW) then
        s.freshAt = nil                       -- window over, or the group dissolved
    end
    if s.freshAt then
        for guid in pairs(s.members) do
            if not OMQ:InGroup(guid) then s.members[guid] = nil end
        end
        return s.members, true
    end
    return s.members, false
end

OMQ:RegisterCommand("falls", function()
    local f = M.fallInfo
    OMQ:Print(string.format("fall damage this session: %s; falls seen %d, amount readable %d, amount secret %d, by health %d, health readable: %s",
        tostring(s and s.fallDmg or "n/a"), f.events, f.readable, f.secret, f.byHealth, tostring(f.healthReadable)))
    OMQ:Print(string.format("from the fall time: %d; last fall %.2f s, %.1f yd, estimate %s",
        f.estimated or 0, f.lastFallTime or 0, f.lastHeight or 0, tostring(f.lastEstimate)))
end, "fall damage counting: what the game lets the addon read")

OMQ:RegisterCommand("dmg", function()
    local list = listFights()
    OMQ:Print(string.format("damage share: me %s of %s (addon users only); fights known to the meter: %s; counted %d",
        tostring(s and s.dmgMine), tostring(s and s.dmgTotal), list and tostring(#list) or "API missing",
        (function() local n = 0 for _ in pairs(counted) do n = n + 1 end return n end)()))
    for _, f in ipairs(list or {}) do
        local id = type(f) == "table" and (f.sessionID or f.id) or f
        local mine, total = fightDamage(id)
        print(string.format("  fight %s: me %s of %s, counted: %s", tostring(id), tostring(mine), tostring(total),
            seenFights[id] and "before load" or (counted[id] and tostring(counted[id].mine) or "no")))
    end
    print("  newest: " .. M:FightDiag())
    print("  overall share (fallback): " .. tostring(M.damageShare))
end, "damage share: what the damage meter shows per fight and what was counted")

OMQ:RegisterCommand("xp", function()
    if not s then return end
    OMQ:Print(string.format("XP this session: %s total, %s from quests, %s from discoveries, discovery text: %s",
        tostring(s.xpGained), tostring(s.xpQuest), tostring(s.xpDisc), tostring(_G.ERR_ZONE_EXPLORED_XP)))
    local p = discoveryPattern == nil and (buildDiscoveryPattern()) or discoveryPattern
    print("  pattern: " .. tostring(p))
    for _, t in ipairs(M.recentTexts) do print("  system text: " .. t) end
end, "XP by source: what the addon counted and the last system messages with numbers")
