-- One More Quest: Bet Check, the logic (chapter 22, decisions 161 to 175)
-- A dad starts a bet: kind, his outcome (a dad) and the stake. The others have 60 s to join with
-- their own outcome or to skip. With 2 or more dads in, the bet runs. Every client with the addon
-- measures itself and reports; the starter's client decides and sends the result. All stakes go
-- into the pot and the winners share it; the losers pay by mail at their next mailbox (Bet/Mail.lua).
--   BS|proto|id|starter|kind|stake|letter     a bet is offered (letter only for the letter bets)
--   BJ|proto|id|guid|pick|1 or 0              join with a pick, or skip
--   BA|proto|id|on or off|guid:pick,...       the join phase is over: the bet runs or is off
--   BV|proto|id|guid|value                    a measurement (first event, or a value at the end)
--   BR|proto|id|winners or off|reason         the result (winners = dad GUIDs, separated by ",")
--   BP|proto|id|from|to|amount                a debt was paid by mail
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local B = {}
OMQ.Bets = B

local JOIN_SECONDS = 60
local MAX_RUNNING = 3              -- decision 169
local COOLDOWN = 300               -- personal, after starting a bet (decision 169)
local STAKE_STEP = 500             -- 5 silver
local DECIDE_GRACE = 6             -- seconds to wait for the values after a timed bet ends
local FIGHT_WAIT = 12              -- "next fight": seconds after the first report
local FIGHT_READ = 9               -- the damage meter is read 1.5, 4 and 8 s after the fight (decision 229)
local ROLL_WAIT = 10
local FALL_DEATH_WINDOW = 3        -- dying this soon after a fall counts as dying from it
local LETTERS = "ABDEFGHKLMNPRST"  -- frequent first letters only
B.JOIN_SECONDS, B.COOLDOWN, B.MAX_RUNNING = JOIN_SECONDS, COOLDOWN, MAX_RUNNING

-- first = the first dad with the event wins; value = the highest value at the end wins
B.KINDS = {
    { id = "death",  name = "Who dies next?",               q = "Who dies next?",                                      mode = "first", untilSession = true },
    { id = "dmg",    name = "Top damage in the next fight", q = "Who does the most damage in the next fight?",         mode = "value", fight = true },
    { id = "run",    name = "Who runs the most?",           q = "Who walks the most yards in 5 minutes?",              mode = "value", seconds = 300 },
    { id = "near",   name = "Who has the next near death?", q = "Who drops below 20% health next (and survives)?",     mode = "first", seconds = 900 },
    { id = "npc",    name = "NPC with a secret letter",     q = "Who first targets an NPC with the secret first letter?", mode = "first", seconds = 900, letter = true },
    { id = "player", name = "Player with a secret letter",  q = "Who first targets a stranger with the secret first letter?", mode = "first", seconds = 900, letter = true },
    { id = "fall",   name = "Biggest fall, still alive",    q = "Who takes the biggest fall damage in one fall and survives?", mode = "value", seconds = 900 },
    { id = "kb",     name = "Next killing blow",            q = "Who lands the next killing blow?",                    mode = "first", untilSession = true },
    { id = "loot",   name = "Most gold looted",             q = "Who loots the most gold in 10 minutes?",              mode = "value", seconds = 600 },
    { id = "roll",   name = "Higher roll",                  q = "Who rolls highest (1-100)?",                          mode = "value", roll = true },
}
local KIND = {}
for _, k in ipairs(B.KINDS) do KIND[k.id] = k end
B.KIND = KIND

local FUNNY = {
    "Luck is a skill, they say.",
    "The dice gods smiled on you today.",
    "Spend it wisely. Or on a mount.",
    "Fair and square. Mostly square.",
    "Somebody will want a rematch.",
    "Easy money. Do not get used to it.",
    "You called it. Show-off.",
    "Buy the dads a round with this.",
}
function B.FunnyLine(seed)
    local i = (tonumber(seed) or math.random(1, 1000)) % #FUNNY + 1
    return FUNNY[i]
end

local bets = {}                     -- id -> bet (the same record on every client)
local order = {}                    -- ids, newest first
local lastStart = -math.huge        -- my own cooldown
local function now() return GetTime() end
local function isSecret(v) return issecretvalue and issecretvalue(v) or false end
local function me() return OMQ:GetSelf() end
local function fire() OMQ:Fire("BETS_CHANGED") end

----------------------------------------------------------------------
-- Money
----------------------------------------------------------------------
function B.Money(copper)
    copper = math.floor(math.abs(copper or 0) + 0.5)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "g" end
    if s > 0 then t[#t + 1] = s .. "s" end
    if c > 0 or #t == 0 then t[#t + 1] = c .. "c" end
    return table.concat(t, " ")
end

-- the maximum stake: the starter's level x 5 silver (decision 162)
function B.MaxStake()
    local lvl = UnitLevel and UnitLevel("player") or 1
    if type(lvl) ~= "number" or isSecret(lvl) or lvl < 1 then lvl = 1 end
    return lvl * 500
end

----------------------------------------------------------------------
-- The ledger: what I owe and what I get, kept until paid (decision 171)
----------------------------------------------------------------------
local function ledger()
    OMQDB.bets = OMQDB.bets or {}
    local guid = UnitGUID("player")
    OMQDB.bets[guid] = OMQDB.bets[guid] or { owe = {}, get = {} }
    return OMQDB.bets[guid]
end
B.Ledger = ledger

-- gold that is not promised to anybody yet
function B.FreeGold()
    local owe = 0
    for _, e in ipairs(ledger().owe) do if e.state ~= "paid" then owe = owe + e.amount end end
    return (GetMoney and GetMoney() or 0) - owe
end

function B.Unsettled()
    local l, sum = ledger(), 0
    for _, e in ipairs(l.get) do if e.state ~= "done" then sum = sum + e.amount end end
    for _, e in ipairs(l.owe) do if e.state ~= "paid" then sum = sum - e.amount end end
    return sum
end

local function nameOf(guid)
    local m = me()
    if m and guid == m.guid then return m.name end
    local u = OMQ.users and OMQ.users[guid]
    return u and u.name or "?"
end

-- the name the mail needs (decision 173): from the hello, else from the unit
local function fullNameOf(guid)
    local u = OMQ.users and OMQ.users[guid]
    if u and u.fullName then return u.fullName end
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitGUID and UnitGUID(unit) == guid then
            local first, second = UnitName(unit)
            if first and not isSecret(first) then
                return (type(second) == "string" and second ~= "") and (first .. " " .. second) or first
            end
        end
    end
    return u and u.name
end
B.FullNameOf = fullNameOf

----------------------------------------------------------------------
-- Who is in the game
----------------------------------------------------------------------
-- me and the online dads (outcomes, and the clients that measure)
function B.Dads()
    local list = {}
    local m = me()
    if m then list[1] = { guid = m.guid, name = m.name, class = m.class, isSelf = true } end
    local others = {}
    for guid, u in pairs(OMQ.users or {}) do
        -- a dad below level 5 takes no part in bets (when the game tells his level)
        if (not m or guid ~= m.guid) and OMQ:IsOnline(u) and (not OMQ.Unlock or OMQ.Unlock:Allows("bets", guid)) then
            others[#others + 1] = { guid = guid, name = u.name, class = u.class, pos = OMQ:GroupPosition(guid) or 9 }
        end
    end
    table.sort(others, function(a, b) if a.pos ~= b.pos then return a.pos < b.pos end return (a.name or "") < (b.name or "") end)
    for _, d in ipairs(others) do list[#list + 1] = d end
    return list
end

local function running()
    local n, kinds = 0, {}
    for _, b in pairs(bets) do
        if b.state == "join" or b.state == "active" then n = n + 1; kinds[b.kind] = true end
    end
    return n, kinds
end

----------------------------------------------------------------------
-- Starting a bet
----------------------------------------------------------------------
-- returns true, or false and the reason
function B:CanStart(kind)
    if not OMQ:GetChannel() then return false, "You need a group with other dads." end
    local wait = lastStart + COOLDOWN - now()
    if wait > 0 then return false, string.format("Your next bet is possible in %d:%02d.", math.floor(wait / 60), math.floor(wait % 60)) end
    local n, kinds = running()
    if n >= MAX_RUNNING then return false, "Three bets are running already." end
    if kind and kinds[kind] then return false, "A bet of this kind is running already." end
    return true
end

local function newId(guid) return tostring(time()) .. string.sub(guid or "x", -4) .. math.random(10, 99) end

function B:Start(kind, pick, stake)
    local k = KIND[kind]
    local m = me()
    if not (k and m) then return false, "Unknown bet." end
    local ok, why = self:CanStart(kind)
    if not ok then return false, why end
    stake = math.floor(tonumber(stake) or 0)
    if stake < 100 or stake > B.MaxStake() then return false, "The stake must be between 1s and " .. B.Money(B.MaxStake()) .. "." end
    if B.FreeGold() < stake then return false, "Not enough gold for this stake (open bet debts count too)." end
    if not pick then return false, "Pick an outcome first." end
    local letter = ""
    if k.letter then local i = math.random(1, #LETTERS); letter = LETTERS:sub(i, i) end
    local id = newId(m.guid)
    lastStart = now()
    self:OnStart(id, m.guid, kind, stake, letter)
    OMQ:Send("BS", id, m.guid, kind, tostring(stake), letter)
    self:Join(id, pick)
    return true, id
end

function B:OnStart(id, starter, kind, stake, letter)
    if bets[id] or not KIND[kind] then return end
    bets[id] = { id = id, kind = kind, starter = starter, starterName = nameOf(starter), stake = stake,
                 letter = (letter ~= "" and letter) or nil, state = "join", joinUntil = now() + JOIN_SECONDS,
                 answers = {}, values = {}, firsts = {} }
    table.insert(order, 1, id)
    OMQ:Fire("BET_OFFERED", id)
    fire()
end

-- join with a pick (a dad's GUID), or skip with pick = nil
function B:Join(id, pick)
    local b, m = bets[id], me()
    if not (b and m) or b.state ~= "join" or b.answers[m.guid] ~= nil then return false end
    if pick and B.FreeGold() < b.stake then return false, "Not enough gold" end
    b.answers[m.guid] = pick or false
    OMQ:Send("BJ", id, m.guid, pick or "-", pick and "1" or "0")
    fire()
    return true
end

----------------------------------------------------------------------
-- Measuring (every client measures itself while a bet runs)
----------------------------------------------------------------------
-- src "f": a random fallback because the own roll line was not seen (decision 223)
-- detail: a short text for the result (decision 227), e.g. the NPC whose name had the letter
local function clean(text)
    if type(text) ~= "string" or isSecret(text) then return "" end
    return (text:gsub("[|:,;]", " "):sub(1, 40))
end
B.CleanDetail = clean
local function report(b, value, src, detail)
    local m = me()
    if not m or b.reported then return end
    local first = KIND[b.kind].mode == "first"
    if not first then b.reported = true end
    -- "first" bets: the value is the time since the bet started, in seconds (decision 227)
    if first then value = math.max(0, now() - (b.startedAt or now())) end
    detail = clean(detail)
    B:OnValue(b.id, m.guid, value, src, detail)
    OMQ:Send("BV", b.id, m.guid, string.format("%.0f", value), src or "", detail)
end

local function session() return OMQ.Measure and OMQ.Measure.Session and OMQ.Measure:Session() end

local function activate(b)
    b.state = "active"
    b.startedAt = now()
    local k = KIND[b.kind]
    if k.seconds then b.endsAt = now() + k.seconds end
    local s = session() or {}
    b.base = { yards = s.yards or 0, near = s.nearDeaths or 0, dmg = s.dmgMine or 0 }
    b.looted, b.bestFall = 0, nil
    if k.roll then
        b.endsAt = now() + ROLL_WAIT
        b.rollAt = now() + 0.5
    end
end

-- the roll result from the chat line (built from the game's own text, works in every language)
local rollPattern
local function buildRollPattern()
    local fmt = _G.RANDOM_ROLL_RESULT
    if type(fmt) ~= "string" then return false end
    fmt = fmt:gsub("%%%d+%$", "%%")              -- "%1$s" -> "%s" (positional formats, decision 228)
    local esc = fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    esc = esc:gsub("%%%d?%$?s", "(.+)"):gsub("%%%d?%$?d", "(%%d+)")
    return "^" .. esc .. "$"
end

B._buildRollPattern = buildRollPattern

local isJudge, bettors        -- defined further below

-- does the name in a chat line belong to this dad? ("Karle" or "Laser Karle")
function B.NameMatches(guid, who)
    if type(who) ~= "string" or who == "" then return false end
    local m = me()
    local names = {}
    if m and guid == m.guid then names = { m.name, m.fullName } else
        local u = OMQ.users and OMQ.users[guid]
        if u then names = { u.name, u.fullName } end
    end
    for _, n in pairs(names) do
        if type(n) == "string" and n ~= "" then
            if who == n or who:sub(1, #n + 1) == n .. " " or who:sub(1, #n + 1) == n .. "-" then return true end
        end
    end
    return false
end

-- a roll line -> who (or the whole line, the name at its start), roll, lo, hi (decision 228):
-- first the game's own format, then a language-free fallback: "<name> ... 57 (1-100)"
function B.ParseRoll(text)
    if rollPattern == nil then rollPattern = buildRollPattern() end
    if rollPattern then
        local ok, who, roll, lo, hi = pcall(string.match, text, rollPattern)
        if ok and who and tonumber(roll) then return who, tonumber(roll), tonumber(lo), tonumber(hi) end
    end
    local roll, lo, hi = text:match("(%d+)%s*%((%d+)%s*%-%s*(%d+)%)%s*%.?%s*$")
    if roll then return text, tonumber(roll), tonumber(lo), tonumber(hi) end
end

B.systemLines, B.secretLines = 0, 0

-- /roll 1-100 by the addon; returns what happened, for the note (decision 230)
function B.DoRoll()
    local fn = RandomRoll or (C_RandomRoll and C_RandomRoll.RandomRoll)
    if not fn then return "API missing" end
    local ok, err = pcall(fn, 1, 100)
    return ok and "sent" or ("error: " .. tostring(err))
end
local function onRollText(text)
    if isSecret(text) then B.secretLines = B.secretLines + 1; return end
    if type(text) ~= "string" then return end
    B.systemLines = B.systemLines + 1
    local who, roll, lo, hi = B.ParseRoll(text)
    if not who or lo ~= 1 or hi ~= 100 then return end
    B.lastRollLine = text
    -- the judge reads every dad's roll straight from the chat line (decision 222): the result no
    -- longer depends on the dads' messages arriving in time, nor on a random value as a fallback
    for _, b in pairs(bets) do
        if b.state == "active" and KIND[b.kind].roll and isJudge(b) then
            b.chatRolls = b.chatRolls or {}
            for _, g in ipairs(bettors(b)) do
                if b.chatRolls[g] == nil and B.NameMatches(g, who) then b.chatRolls[g] = tonumber(roll) end
            end
        end
    end
    local m = me()
    if not (m and B.NameMatches(m.guid, who)) then return end
    for _, b in pairs(bets) do
        if b.state == "active" and KIND[b.kind].roll and b.rolled and not b.reported then report(b, tonumber(roll)) end
    end
end

local function firstLetter(name)
    if type(name) ~= "string" or isSecret(name) or name == "" then return nil end
    local c = name:match("^[%z\1-\127\194-\244][\128-\191]*")
    return c and c:upper()
end
B.FirstLetter = firstLetter

local function onTarget()
    if not (UnitExists and UnitExists("target")) then return end
    local isPlayer = UnitIsPlayer and UnitIsPlayer("target")
    local guid = UnitGUID("target")
    local inGroup = guid and (OMQ:GroupPosition(guid) ~= nil or (UnitInParty and UnitInParty("target")))
    local m = me()
    if m and guid == m.guid then return end
    local letter = firstLetter((UnitName("target")))
    for _, b in pairs(bets) do
        if b.state == "active" and b.letter and letter == b.letter then
            if (b.kind == "npc" and not isPlayer) or (b.kind == "player" and isPlayer and not inGroup) then
                report(b, 1, nil, (UnitName("target")))
            end
        end
    end
end

local fallSeen = 0
local lastFallAt = -math.huge
local lastDeathAt = -math.huge
-- was I falling or did I land a fall within the death window? (decision 224: PLAYER_DEAD comes at
-- the moment of the deadly landing, before the half-second tick has seen the new fall)
local function fellRecently()
    local t = now()
    local info = OMQ.Measure and OMQ.Measure.fallInfo
    if IsFalling and IsFalling() then return true end
    if info and info.fallingAt and t - info.fallingAt <= FALL_DEATH_WINDOW then return true end
    return t - lastFallAt <= FALL_DEATH_WINDOW
end
B._fellRecently = fellRecently
local function tickMeasure()
    local s = session()
    local t = now()
    for _, b in pairs(bets) do
        if b.state == "active" and not b.reported then
            local k = b.kind
            if k == "near" and s and (s.nearDeaths or 0) > b.base.near then report(b, 1)
            elseif k == "run" and b.endsAt and t >= b.endsAt then report(b, (s and s.yards or 0) - b.base.yards)
            elseif k == "loot" and b.endsAt and t >= b.endsAt then report(b, b.looted or 0)
            elseif k == "fall" and b.endsAt and t >= b.endsAt then report(b, b.bestFall or 0)
            elseif k == "roll" and b.rollAt and t >= b.rollAt and not b.rolled then
                -- decision 230/231: the call is checked (no second roll: a missed line is a reading problem)
                b.rolled = true
                b.rollFallback = t + 6
                b.rollCall = B.DoRoll()
            elseif k == "roll" and b.rollFallback and t >= b.rollFallback then
                -- the chat line never came: a random roll counts, and everybody sees that (decision 223)
                local v = math.random(1, 100)
                report(b, v, "f")
                OMQ:Print(string.format("Bet: your roll line was not seen - a random %d counts for you (roll %s; %s)", v,
                    tostring(b.rollCall),
                    B.lastRollLine and ("last roll line: \"" .. B.lastRollLine .. "\"")
                    or string.format("system lines seen %d, secret %d, format %s", B.systemLines, B.secretLines,
                        tostring(_G.RANDOM_ROLL_RESULT))))
            elseif k == "dmg" and b.fightEndAt and t >= b.fightEndAt then
                local d = math.max(0, ((s and s.dmgMine) or 0) - (b.fightBase or 0))
                report(b, d)
                if d == 0 and OMQ.Measure and OMQ.Measure.FightDiag then
                    OMQ:Print("Bet: your damage in that fight was read as 0 (" .. OMQ.Measure:FightDiag() .. ")")
                end
            end
        end
    end
    -- a new fall: its damage counts for the fall bets of this client (the biggest one)
    local info = OMQ.Measure and OMQ.Measure.fallInfo
    if info and (info.events or 0) > fallSeen then
        fallSeen = info.events
        lastFallAt = t
        local amount = info.lastAmount
        -- the deadly fall can be seen after the death: dead now, or died within the window, is out
        local died = (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or (t - lastDeathAt <= FALL_DEATH_WINDOW)
        for _, b in pairs(bets) do
            if b.state == "active" and b.kind == "fall" and not b.reported and not b.fellDead then
                if died then
                    b.fellDead = true; b.pendingFall = nil; b.bestFall = -1
                elseif type(amount) == "number" and not isSecret(amount) then
                    b.pendingFall = { amount = amount, at = t }
                end
            end
        end
    end
    for _, b in pairs(bets) do
        local p = b.pendingFall
        if p and t - p.at > FALL_DEATH_WINDOW then
            b.pendingFall = nil
            if not b.fellDead and (not b.bestFall or p.amount > b.bestFall) then b.bestFall = p.amount end
        end
    end
end

local lootOpen, lootClosedAt, moneyMsgAt, lastMoney = false, -math.huge, -math.huge, nil
local function onMoney()
    local money = GetMoney and GetMoney() or 0
    local gain = lastMoney and money - lastMoney or 0
    lastMoney = money
    if gain <= 0 then return end
    local t = now()
    -- only money from loot counts (decision 168): while the loot window is open, or right after a loot money line
    if not (lootOpen or t - lootClosedAt < 0.5 or t - moneyMsgAt < 1) then return end
    for _, b in pairs(bets) do
        if b.state == "active" and b.kind == "loot" and not b.reported then b.looted = (b.looted or 0) + gain end
    end
end

----------------------------------------------------------------------
-- Deciding (the starter's client)
----------------------------------------------------------------------
-- the starter's client decides; bets of simulated dads are decided by my client (Sim/Sim.lua)
isJudge = function(b)
    local m = me()
    return m and (b.starter == m.guid or (OMQ.Sim and OMQ.Sim:IsSim(b.starter))) or false
end

bettors = function(b)
    local list = {}
    for guid, pick in pairs(b.answers) do if pick then list[#list + 1] = guid end end
    table.sort(list)
    return list
end
B.Bettors = bettors

-- who pays whom: all stakes in the pot, the winners share it (decision 162)
function B.Payouts(b, winners)
    local win = {}
    for _, g in ipairs(winners or {}) do win[g] = true end
    local W, L = {}, {}
    for _, g in ipairs(bettors(b)) do
        if win[b.answers[g]] then W[#W + 1] = g else L[#L + 1] = g end
    end
    if #W == 0 or #L == 0 then return nil, (#W == 0 and "nobody was right" or "everybody was right") end
    table.sort(W)
    local out = {}
    local per = math.floor(b.stake / #W)
    for _, loser in ipairs(L) do
        for i, w in ipairs(W) do
            local amount = per + ((i == 1) and (b.stake - per * #W) or 0)
            if amount > 0 then out[#out + 1] = { from = loser, to = w, amount = amount } end
        end
    end
    return out, nil, W, L
end

local function decide(b, winners, reason)
    if b.state ~= "active" or not isJudge(b) then return end
    local list = winners and table.concat(winners, ",") or ""
    local fv = {}
    for _, e in ipairs(b.finalValues or {}) do
        fv[#fv + 1] = e.guid .. ":" .. string.format("%.0f", e.value) .. ":" .. e.src .. ":" .. clean(e.detail)
    end
    OMQ:Send("BR", b.id, (winners and #winners > 0) and list or "off", reason or "", table.concat(fv, ","))
    B:OnResult(b.id, winners, reason)
end

local function judgeValues(b)
    local best, winners = nil, {}
    local values = b.values
    if b.chatRolls then
        values = {}
        for g, v in pairs(b.values) do values[g] = v end
        for g, v in pairs(b.chatRolls) do values[g] = v end      -- what everybody saw in the chat counts
    end
    -- the values that decided, with their source, for everybody to see (decision 223)
    b.finalValues = {}
    for guid, v in pairs(values) do
        local src = (b.chatRolls and b.chatRolls[guid] ~= nil) and "c" or ((b.valueSrc and b.valueSrc[guid]) or "r")
        b.finalValues[#b.finalValues + 1] = { guid = guid, value = v, src = src }
    end
    table.sort(b.finalValues, function(x, y) return x.value > y.value end)
    for guid, v in pairs(values) do
        if v >= 0 then
            if not best or v > best then best, winners = v, { guid }
            elseif v == best then winners[#winners + 1] = guid end
        end
    end
    if not best or best <= 0 and b.kind ~= "roll" then return nil end
    table.sort(winners)
    return winners
end

local function tickJudge()
    local t = now()
    for _, b in pairs(bets) do
        if isJudge(b) then
            if b.state == "join" then
                local answered, dads = 0, B.Dads()
                for _, d in ipairs(dads) do if b.answers[d.guid] ~= nil then answered = answered + 1 end end
                if t >= b.joinUntil or answered >= #dads then
                    local ins = bettors(b)
                    local parts = {}
                    for _, g in ipairs(ins) do parts[#parts + 1] = g .. ":" .. b.answers[g] end
                    local on = #ins >= 2
                    OMQ:Send("BA", b.id, on and "on" or "off", table.concat(parts, ","))
                    B:OnActive(b.id, on, table.concat(parts, ","))
                end
            elseif b.state == "active" then
                local k = KIND[b.kind]
                if k.mode == "value" then
                    local due = (b.endsAt and t >= b.endsAt + DECIDE_GRACE) or (b.decideAt and t >= b.decideAt)
                    if k.roll and b.chatRolls then
                        local all = true
                        for _, g in ipairs(bettors(b)) do if b.chatRolls[g] == nil then all = false end end
                        if all then due = true end
                    end
                    if due then
                        local w = judgeValues(b)
                        decide(b, w, w and "" or "nothing measured")
                    end
                elseif b.endsAt and t >= b.endsAt + DECIDE_GRACE then
                    decide(b, nil, "time is up")
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Incoming
----------------------------------------------------------------------
function B:OnActive(id, on, list)
    local b = bets[id]
    if not b or b.state ~= "join" then return end
    -- the starter's list is the truth (everybody gets the same picks)
    b.answers = {}
    for g, p in tostring(list or ""):gmatch("([^:,]+):([^:,]+)") do b.answers[g] = p end
    if on then activate(b) else b.state = "off"; b.reason = "fewer than 2 dads" end
    OMQ:Fire("BET_ACTIVE", id, on)
    fire()
end

function B:OnValue(id, guid, value, src, detail)
    local b = bets[id]
    if not b or b.state ~= "active" then return end
    local k = KIND[b.kind]
    if k.mode == "first" then
        if isJudge(b) and not b.decided then
            b.decided = true
            -- what decided, for everybody (decision 227): who, after how long, and what
            b.finalValues = { { guid = guid, value = tonumber(value) or 0, src = "t", detail = clean(detail) } }
            decide(b, { guid }, "")
        end
    else
        if b.values[guid] == nil then
            b.values[guid] = tonumber(value) or 0
            b.valueSrc = b.valueSrc or {}
            b.valueSrc[guid] = (src == "f") and "f" or "r"
        end
        if k.fight and not b.decideAt then b.decideAt = now() + FIGHT_WAIT end
    end
    fire()
end

function B:OnResult(id, winners, reason)
    local b = bets[id]
    if not b or b.state == "done" or b.state == "off" then return end
    local pays, why, W = nil, reason, nil
    if winners and #winners > 0 then pays, why, W = B.Payouts(b, winners) end
    b.winnerDads = winners
    if not pays then
        b.state, b.reason = "off", (why and why ~= "" and why) or "no result"
    else
        b.state, b.pays = "done", pays
        local m = me()
        local l = ledger()
        local s = session()
        local net = 0
        for _, p in ipairs(pays) do
            if p.from == m.guid then
                l.owe[#l.owe + 1] = { id = id, kind = b.kind, to = p.to, toName = nameOf(p.to), toFull = fullNameOf(p.to),
                                      amount = p.amount, state = "open", at = time() }
                net = net - p.amount
            elseif p.to == m.guid then
                l.get[#l.get + 1] = { id = id, kind = b.kind, from = p.from, fromName = nameOf(p.from), amount = p.amount,
                                      state = "open", at = time() }
                net = net + p.amount
            end
        end
        if s then
            s.gamble = (s.gamble or 0) + net
            for _, g in ipairs(W or {}) do if g == m.guid then s.betsWon = (s.betsWon or 0) + 1 end end
        end
    end
    OMQ:Fire("BET_RESULT", id)
    fire()
end

OMQ:RegisterMessage("BS", function(f)
    local id, starter, kind, stake = f[1], f[2], f[3], tonumber(f[4])
    local m = me()
    if not (id and starter and stake) or (m and starter == m.guid) then return end
    local u = OMQ.users and OMQ.users[starter]
    if not (u and OMQ:IsOnline(u)) then return end
    if OMQ.Unlock and not OMQ.Unlock:Has("bets") then return end      -- below level 5: no bets
    B:OnStart(id, starter, kind, stake, f[5] or "")
end)

OMQ:RegisterMessage("BJ", function(f)
    local b = bets[f[1] or ""]
    local guid = f[2]
    local m = me()
    if not b or not guid or (m and guid == m.guid) or b.state ~= "join" then return end
    b.answers[guid] = (f[4] == "1" and f[3] ~= "-") and f[3] or false
    fire()
end)

OMQ:RegisterMessage("BA", function(f)
    local b = bets[f[1] or ""]
    local m = me()
    if not b or (m and b.starter == m.guid) then return end
    B:OnActive(b.id, f[2] == "on", f[3])
end)

OMQ:RegisterMessage("BV", function(f)
    local m = me()
    if not f[2] or (m and f[2] == m.guid) then return end
    B:OnValue(f[1], f[2], tonumber(f[3]), f[4], f[5])
end)

OMQ:RegisterMessage("BR", function(f)
    local b = bets[f[1] or ""]
    local m = me()
    if not b or (m and b.starter == m.guid) then return end
    local winners
    if f[2] and f[2] ~= "off" then
        winners = {}
        for g in f[2]:gmatch("[^,]+") do winners[#winners + 1] = g end
    end
    if f[4] and f[4] ~= "" then
        b.finalValues = {}
        for entry in f[4]:gmatch("[^,]+") do
            local g, v, src, detail = entry:match("^([^:]+):([%d%.%-]+):(%a):?(.*)$")
            if g then b.finalValues[#b.finalValues + 1] = { guid = g, value = tonumber(v), src = src, detail = detail } end
        end
    end
    B:OnResult(b.id, winners, f[3])
end)

-- a debtor paid: the winner's entry becomes "sent", the mail waits in his mailbox
OMQ:RegisterMessage("BP", function(f)
    local id, from, to, amount = f[1], f[2], f[3], tonumber(f[4])
    local m = me()
    if not (m and to == m.guid) then return end
    for _, e in ipairs(ledger().get) do
        if e.id == id and e.from == from and e.state == "open" then e.state = "sent"; break end
    end
    fire()
end)

function B:Paid(entry)
    entry.state = "paid"
    entry.paidAt = time()
    local m = me()
    if m then OMQ:Send("BP", entry.id, m.guid, entry.to, tostring(entry.amount)) end
    fire()
end

----------------------------------------------------------------------
-- Session end: bets that last a session are off without an event
----------------------------------------------------------------------
local function sessionOver()
    for _, b in pairs(bets) do
        if b.state == "active" and isJudge(b) then
            if KIND[b.kind].mode == "value" then
                local w = judgeValues(b)
                decide(b, w, w and "" or "the session ended")
            else
                decide(b, nil, (b.kind == "death") and "nobody died" or "the session ended")
            end
        elseif b.state == "join" then
            b.state, b.reason = "off", "the session ended"
        end
    end
    fire()
end
OMQ:On("SESSION_RESET", sessionOver)

----------------------------------------------------------------------
-- Views for the UI
----------------------------------------------------------------------
function B:Get(id) return bets[id] end
function B:List()
    local out = {}
    for _, id in ipairs(order) do out[#out + 1] = bets[id] end
    return out
end
function B:Running()
    local out = {}
    for _, id in ipairs(order) do
        local b = bets[id]
        if b.state == "join" or b.state == "active" then out[#out + 1] = b end
    end
    return out
end
function B:CooldownLeft() return math.max(0, lastStart + COOLDOWN - now()) end

-- the hover on the Bet Check icon (decision 166)
function B:FillTooltip(tt)
    local l = ledger()
    local any = false
    local function line(text, amount, r, g, bl)
        if tt.AddDoubleLine then tt:AddDoubleLine(text, amount, 0.85, 0.85, 0.85, r, g, bl) else tt:AddLine(text .. "  " .. amount) end
    end
    for _, e in ipairs(l.owe) do
        if e.state ~= "paid" then
            if not any then tt:AddLine(" "); tt:AddLine("You owe", 0.72, 0.63, 0.42); any = true end
            line((e.toName or "?") .. " - " .. (KIND[e.kind] and KIND[e.kind].name or e.kind), B.Money(e.amount), 0.88, 0.47, 0.42)
        end
    end
    local head = false
    for _, e in ipairs(l.get) do
        if e.state ~= "done" then
            if not head then tt:AddLine(" "); tt:AddLine("You get", 0.72, 0.63, 0.42); head = true end
            line((e.fromName or "?") .. " - " .. (KIND[e.kind] and KIND[e.kind].name or e.kind) .. (e.state == "sent" and " (in the mail)" or ""),
                B.Money(e.amount), 0.49, 0.78, 0.44)
        end
    end
    local u = B.Unsettled()
    tt:AddLine(" ")
    line("Unsettled business", (u > 0 and "+" or (u < 0 and "-" or "")) .. B.Money(u), u >= 0 and 0.49 or 0.88, u >= 0 and 0.78 or 0.47, u >= 0 and 0.44 or 0.42)
    local cd = self:CooldownLeft()
    if cd > 0 then tt:AddLine(string.format("Your next bet: in %d:%02d", math.floor(cd / 60), math.floor(cd % 60)), 0.6, 0.63, 0.68) end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
local HANDLERS = {
    PLAYER_DEAD = function()
        lastDeathAt = now()
        local fell = fellRecently()
        for _, b in pairs(bets) do
            if b.state == "active" and b.kind == "death" then report(b, 1) end
            if b.state == "active" and b.kind == "fall" and fell then
                b.fellDead = true; b.pendingFall = nil; b.bestFall = -1        -- dying from the fall: out
            end
        end
    end,
    PARTY_KILL = function(killer)
        local ok, mine = pcall(function() return killer == UnitGUID("player") end)
        if not (ok and mine) then return end
        for _, b in pairs(bets) do if b.state == "active" and b.kind == "kb" then report(b, 1) end end
    end,
    PLAYER_TARGET_CHANGED = onTarget,
    PLAYER_REGEN_DISABLED = function()
        local s = session()
        for _, b in pairs(bets) do
            if b.state == "active" and b.kind == "dmg" and not b.fightBase then b.fightBase = s and s.dmgMine or 0 end
        end
    end,
    PLAYER_REGEN_ENABLED = function()
        for _, b in pairs(bets) do
            if b.state == "active" and b.kind == "dmg" and b.fightBase and not b.fightEndAt then b.fightEndAt = now() + FIGHT_READ end
        end
    end,
    PLAYER_MONEY = onMoney,
    LOOT_OPENED = function() lootOpen = true end,
    LOOT_CLOSED = function() lootOpen = false; lootClosedAt = now() end,
    CHAT_MSG_MONEY = function() moneyMsgAt = now() end,
    CHAT_MSG_SYSTEM = onRollText,
}
for e in pairs(HANDLERS) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event, ...)
    local ok, err = pcall(HANDLERS[event], ...)
    if not ok then OMQ:Error("bets " .. event, err) end
end)

OMQ:On("READY", function()
    lastMoney = GetMoney and GetMoney() or 0
    local info = OMQ.Measure and OMQ.Measure.fallInfo
    fallSeen = info and info.events or 0
    C_Timer.NewTicker(0.5, function()
        local ok, err = pcall(tickMeasure)
        if not ok then OMQ:Error("bets measure", err) end
        ok, err = pcall(tickJudge)
        if not ok then OMQ:Error("bets judge", err) end
    end)
end)

OMQ:RegisterCommand("bet", function(arg)
    if arg == "clear" then
        local l = ledger()
        l.owe, l.get = {}, {}
        OMQ:Print("bet ledger cleared")
        fire()
        return
    end
    if OMQ.BetUI then OMQ.BetUI:ToggleCreate() end
end, "Bet Check: open the bet window (/omq bet clear empties your bet ledger)")

-- test hooks
B._tickMeasure, B._tickJudge, B._report = tickMeasure, tickJudge, report
function B:_SetLastStart(t) lastStart = t end
