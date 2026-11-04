-- One More Quest: match between dads (from level 15, started from the check bar)
-- Every dad brings foes from his own counters (Stats/Tally.lua, kills.npc). Five rounds: each dad picks one
-- of three random foes in secret, the caller names a value, everybody reveals, the highest value scores
-- (ties: all of them), the lowest calls the next round. Each value once per match. A tie at the end goes
-- to extra rounds between the leaders. The host (who challenged) decides the result of every round.
-- Messages: MI invite, MJ answer, MS start, MP picked, MC called, MR revealed, MW round result,
-- MQ left, MX cancelled. Players travel as their place in the start list (1 = host).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local M = {}
OMQ.Match = M
local L = OMQ.Ledger

M.MIN_LEVEL = 15
M.ROUNDS = 5
M.MAX_PLAYERS = 5
M.OFFERS = 3
M.INVITE_TIME = 30
M.PICK_TIME = 30
M.CALL_TIME = 30
M.GRACE = 5
M.REVEAL_WAIT = 10
M.REVEAL_HOLD = 6
M.LOST_AFTER = 120
M.MAX_RIVALS = 50

M.STATS = {
    { id = "lvl", name = "Level", hint = "Level of the foe",
      desc = "The level of the foe. For foes you met at several levels, the highest one counts." },
    { id = "kills", name = "Kills", hint = "How often it died",
      desc = "How often this foe died while you were there, by your hand or your group's." },
    { id = "blows", name = "Killing Blows", hint = "Your own killing blows",
      desc = "How often you dealt the killing blow yourself." },
    { id = "rarity", name = "Rarity", hint = "Normal 1 up to boss 5",
      desc = "How rare the foe is: Normal 1, Rare 2, Elite 3, Rare Elite 4, Boss 5." },
    { id = "daring", name = "Daring", hint = "Its level minus yours at the first kill",
      desc = "The foe's level minus your level when you first killed it. High means you started the fight as the underdog." },
    { id = "veteran", name = "Veteran", hint = "Days since the first kill",
      desc = "How many days ago you killed this foe for the first time." },
    { id = "grudge", name = "Grudge", hint = "How often it killed you",
      desc = "How often this foe killed you. Revenge counts." },
    { id = "loyalty", name = "Loyalty", hint = "Days with a kill",
      desc = "On how many different days you killed this foe." },
}
M.byStat = {}
for _, s in ipairs(M.STATS) do M.byStat[s.id] = s end
M.RARITY = { normal = 1, rare = 2, elite = 3, rareelite = 4, boss = 5 }

local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2)
end
local function split(s)
    local out = {}
    for part in tostring(s or ""):gmatch("[^,]+") do out[#out + 1] = part end
    return out
end
local function now() return GetTime() end

M.diag = {}
local function note(k) M.diag[k] = (M.diag[k] or 0) + 1 end
M.Note = note

----------------------------------------------------------------------
-- My foes and their values
----------------------------------------------------------------------
function M:Book() return OMQ.Tally and OMQ.Tally.Book() end
function M:Record()
    local b = self:Book()
    if not b then return nil end
    b.match = b.match or { n = 0, w = 0, perfect = 0, sd = 0, zero = 0, full = 0, lucky = 0, rivals = {} }
    b.match.rivals = b.match.rivals or {}
    return b.match
end

local function deathsBy(b, id)
    local n = 0
    for _, d in ipairs(b.deaths or {}) do if d.why == "npc" and d.id == id then n = n + 1 end end
    return n
end

-- everything one foe of mine shows in the match
function M:Mob(id, b)
    b = b or self:Book()
    local n = b and b.kills and b.kills.npc and b.kills.npc[id]
    if type(n) ~= "table" then return nil end
    local lvl = n.hi or n.lo or 0
    local days = n.t and math.floor(math.max(0, time() - n.t) / 86400) or 0
    local mob = { id = id, name = n.nm or ("Foe " .. id), level = lvl, rank = n.rk or "normal", type = n.ty or "none",
                  zone = n.zn, kills = n.n or 0, first = n.t, firstLevel = n.l }
    mob.vals = {
        lvl = lvl,
        kills = n.n or 0,
        blows = n.m or 0,
        rarity = M.RARITY[n.rk or "normal"] or 1,
        daring = (lvl > 0 and n.l) and (lvl - n.l) or 0,
        veteran = days,
        grudge = deathsBy(b, id),
        loyalty = math.max(n.dy or 0, (n.n or 0) > 0 and 1 or 0),
    }
    return mob
end

-- ids of all my foes (named ones first; unnamed only when there are too few)
function M:Pool(b)
    b = b or self:Book()
    local named, other = {}, {}
    for id, n in pairs(b and b.kills and b.kills.npc or {}) do
        if type(id) == "number" and type(n) == "table" and (n.n or 0) > 0 then
            if n.nm then named[#named + 1] = id else other[#other + 1] = id end
        end
    end
    table.sort(named); table.sort(other)
    if #named >= self.OFFERS then return named end
    for _, id in ipairs(other) do named[#named + 1] = id end
    return named
end

-- three random foes, without the ones I already played in this match
-- (fresh foes first; when there are too few, played ones fill up to three)
function M:Draw(skip)
    local fresh, played, out = {}, {}, {}
    for _, id in ipairs(self:Pool()) do
        if skip and skip[id] then played[#played + 1] = id else fresh[#fresh + 1] = id end
    end
    for _, pool in ipairs({ fresh, played }) do
        while #out < self.OFFERS and #pool > 0 do
            out[#out + 1] = table.remove(pool, math.random(1, #pool))
        end
    end
    return out
end

-- only the first name of a dad (characters have two-part names on WoW Forever)
function M.Short(name)
    return tostring(name or "?"):match("^%S+") or "?"
end
local short = M.Short

function M:Unlocked()
    local level = UnitLevel and call(UnitLevel, "player")
    if not num(level) or level < self.MIN_LEVEL then return false end
    if not (L and L:Open()) then return false end
    return #self:Pool() > 0
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
M.cur = nil        -- the running match
M.invite = nil     -- an open invitation: { id, host, hostName, deadline }

local function changed() OMQ:Fire("MATCH_UPDATE") end

local function out(msg, ...)
    local c = M.cur
    if c and c.demo then return true end
    return OMQ:Send(msg, ...)
end

function M:Me() return self.cur and self.cur.players[self.cur.me] end
function M:IsHost() return self.cur and self.cur.me == 1 end
function M:Active()
    local c = self.cur
    return c ~= nil and c.phase ~= "done"
end

-- the players still in the match (and, in extra rounds, only the leaders)
function M:InRound(idx)
    local c = self.cur
    local p = c and c.players[idx]
    if not p or p.left then return false end
    return c.only == nil or c.only[idx] == true
end
function M:RoundPlayers()
    local list = {}
    for i in ipairs(self.cur.players) do if self:InRound(i) then list[#list + 1] = i end end
    return list
end
function M:FreeStats()
    local list = {}
    for _, s in ipairs(self.STATS) do if not self.cur.used[s.id] then list[#list + 1] = s.id end end
    return list
end

local function idxOf(guid)
    local c = M.cur
    if not c then return nil end
    for i, p in ipairs(c.players) do if p.guid == guid then return i end end
    return nil
end

----------------------------------------------------------------------
-- Challenge and invitation
----------------------------------------------------------------------
local function groupDads()
    local list = {}
    local me = OMQ:GetSelf()
    for guid, u in pairs(OMQ.users or {}) do
        -- a dad below level 15 is not invited (when the game tells his level)
        if (not me or guid ~= me.guid) and OMQ:IsOnline(u) and (not OMQ.Unlock or OMQ.Unlock:Allows("duel", guid)) then
            list[#list + 1] = { guid = guid, name = short(u.name) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end
M._GroupDads = groupDads

function M:Challenge()
    if self:Active() then return false, "a match is running" end
    if not self:Unlocked() then return false, "not ready yet" end
    if InCombatLockdown and InCombatLockdown() then return false, "not in combat" end
    if not OMQ:GetChannel() then return false, "join a group with other dads" end
    local dads = groupDads()
    if #dads == 0 then return false, "no other dad in the group" end
    local me = OMQ:GetSelf()
    local id = tostring(time() % 100000) .. tostring(math.random(100, 999))
    self.cur = { id = id, me = 1, phase = "invite", deadline = now() + self.INVITE_TIME,
                 players = { { guid = me.guid, name = short(me.name), score = 0 } }, answers = {}, asked = {} }
    for _, d in ipairs(dads) do self.cur.asked[d.guid] = d.name end
    out("MI", id, me.guid, me.name)
    note("challenge")
    changed()
    return true
end

-- a demo against simulated dads, nothing is sent (for trying the window alone)
function M:Demo(count)
    if self:Active() then return false, "a match is running" end
    if #self:Pool() == 0 then return false, "no foes yet" end
    local me = OMQ:GetSelf()
    if not me then return false, "not ready" end
    count = math.max(1, math.min(4, tonumber(count) or 1))
    local names = { "Bot Alpha", "Bot Bravo", "Bot Charlie", "Bot Delta" }
    local players = { { guid = me.guid, name = short(me.name), score = 0 } }
    for i = 1, count do players[#players + 1] = { guid = "bot" .. i, name = names[i], score = 0, bot = true } end
    self.cur = { id = "demo", me = 1, demo = true, players = players }
    self:Begin(1)
    return true
end

local function startMatch()
    local c = M.cur
    local accepted = {}
    for guid, a in pairs(c.answers) do if a.yes then accepted[#accepted + 1] = { guid = guid, name = a.name } end end
    table.sort(accepted, function(a, b) return a.name < b.name end)
    if #accepted == 0 then
        OMQ:Print("no dad accepted the duel")
        out("MX", c.id)
        M.cur = nil
        note("noone")
        changed()
        return
    end
    for _, a in ipairs(accepted) do
        if #c.players < M.MAX_PLAYERS then c.players[#c.players + 1] = { guid = a.guid, name = a.name, score = 0 } end
    end
    local guids, names = {}, {}
    for i, p in ipairs(c.players) do guids[i] = p.guid; names[i] = p.name end
    out("MS", c.id, table.concat(guids, ","), table.concat(names, ","))
    M:Begin(1)
end

function M:Answer(yes)
    local inv = self.invite
    if not inv then return false end
    self.invite = nil
    local me = OMQ:GetSelf()
    if not me then return false end
    if yes and (self:Active() or not self:Unlocked()) then yes = false end
    OMQ:Send("MJ", inv.id, me.guid, me.name, yes and 1 or 0)
    if yes then self.waiting = { id = inv.id, host = inv.host, hostName = inv.hostName, deadline = now() + self.INVITE_TIME + 15 } end
    note(yes and "accept" or "decline")
    changed()
    return true
end

local function onInvite(f)
    local id, host, hostName = f[1], f[2], f[3]
    local me = OMQ:GetSelf()
    if not id or not me or host == me.guid then return end
    -- not ready or busy: a quiet no, nothing is shown
    if not M:Unlocked() or M:Active() or M.invite then
        OMQ:Send("MJ", id, me.guid, me.name, 0)
        note("invite.quiet")
        return
    end
    M.invite = { id = id, host = host, hostName = short(hostName), deadline = now() + M.INVITE_TIME }
    note("invite")
    OMQ:Fire("MATCH_INVITE", M.invite)
    changed()
end

local function onAnswer(f)
    local c = M.cur
    local id, guid, name, yes = f[1], f[2], f[3], f[4] == "1"
    if not c or c.id ~= id or c.phase ~= "invite" or not M:IsHost() then return end
    c.answers[guid] = { yes = yes, name = short(name) }
    local all = true
    for g in pairs(c.asked) do if not c.answers[g] then all = false end end
    changed()
    if all then startMatch() end
end

local function onStart(f)
    local id = f[1]
    local w = M.waiting
    if M.invite and M.invite.id == id then M.invite = nil; changed() end
    if not w or w.id ~= id then return end
    M.waiting = nil
    local me = OMQ:GetSelf()
    local guids, names = split(f[2]), split(f[3])
    local players, mine = {}, nil
    for i, g in ipairs(guids) do
        players[i] = { guid = g, name = short(names[i]), score = 0 }
        if g == me.guid then mine = i end
    end
    if not mine then note("start.without"); changed(); return end
    M.cur = { id = id, me = mine, players = players }
    M:Begin(1)
end

----------------------------------------------------------------------
-- Rounds
----------------------------------------------------------------------
-- a fresh round: who plays it and who calls
function M:Begin(round, caller, only)
    local c = self.cur
    c.round, c.caller, c.only = round, caller or 1, only
    c.used = c.used or {}
    c.picks = c.picks or {}
    c.calls = c.calls or {}
    c.reveals = c.reveals or {}
    c.results = c.results or {}
    c.played = c.played or {}
    c.picks[round] = c.picks[round] or {}
    c.reveals[round] = c.reveals[round] or {}
    c.heard = now()
    c.choice, c.offers = nil, nil
    if self:InRound(c.me) then
        c.phase = "pick"
        c.offers = self:Draw(c.played)
    else
        c.phase = "watch"
    end
    c.deadline = now() + self.PICK_TIME
    c.phaseAt = now()
    note("round")
    if c.demo then self:BotsPick() end
    self:CheckPicks()
    changed()
end

-- my pick (index into the offers)
function M:Pick(i)
    local c = self.cur
    if not c or c.phase ~= "pick" or not c.offers or not c.offers[i] then return false end
    c.choice = c.offers[i]
    c.played[c.choice] = true
    c.picks[c.round][c.me] = true
    c.phase = "picked"
    out("MP", c.id, c.round, c.me)
    self:CheckPicks()
    changed()
    return true
end

local function everyonePicked()
    local c = M.cur
    for _, i in ipairs(M:RoundPlayers()) do if not c.picks[c.round][i] then return false end end
    return true
end

-- all picked (or the time is up): the caller names a value
function M:CheckPicks()
    local c = self.cur
    if not c or (c.phase ~= "picked" and c.phase ~= "watch") then return end
    if c.calls[c.round] then self:OnCall(c.round, c.calls[c.round]); return end
    if not everyonePicked() and now() < c.phaseAt + self.PICK_TIME + self.GRACE then return end
    if c.callRound == c.round then return end
    c.callRound = c.round
    c.phase = c.phase == "watch" and "watch" or "call"
    c.callAt = now()
    c.deadline = now() + self.CALL_TIME
    if c.demo and c.players[c.caller].bot then
        C_Timer.After(1.5, function() if M.cur == c and not c.calls[c.round] then M:BotCall() end end)
    end
    changed()
end

function M:Call(stat)
    local c = self.cur
    if not c or c.phase ~= "call" or c.caller ~= c.me or c.used[stat] or not self.byStat[stat] then return false end
    out("MC", c.id, c.round, c.me, stat)
    self:OnCall(c.round, stat)
    return true
end

local function randomFree()
    local free = M:FreeStats()
    return free[math.random(1, math.max(1, #free))] or "kills"
end

-- the value is named: reveal my foe
function M:OnCall(round, stat)
    local c = self.cur
    c.calls[round] = stat
    if round ~= c.round or c.revealedAt then return end
    if c.phase == "pick" then return end
    c.used[stat] = true
    c.stat = stat
    c.revealedAt = now()
    c.phase = "reveal"
    c.deadline = now() + self.REVEAL_WAIT
    if self:InRound(c.me) and c.choice then
        local mob = self:Mob(c.choice)
        if mob then
            local rec = { id = mob.id, value = mob.vals[stat] or 0, level = mob.level, rank = mob.rank, type = mob.type,
                          name = mob.name, zone = mob.zone or "", kills = mob.kills }
            c.reveals[round][c.me] = rec
            out("MR", c.id, round, c.me, rec.id, rec.value, rec.level, rec.rank, rec.type, rec.name, rec.zone)
        end
    end
    if c.demo then self:BotsReveal(round, stat) end
    self:CheckReveals()
    changed()
end

-- the host: all revealed (or the time is up) -> who scores, who calls next
function M:CheckReveals()
    local c = self.cur
    if not c or c.phase ~= "reveal" or not self:IsHost() then return end
    local r = c.round
    local all = true
    for _, i in ipairs(self:RoundPlayers()) do if not c.reveals[r][i] then all = false end end
    if not all and now() < c.revealedAt + self.REVEAL_WAIT then return end
    local best, worst = nil, nil
    for _, i in ipairs(self:RoundPlayers()) do
        local rec = c.reveals[r][i]
        if rec then
            if not best or rec.value > best then best = rec.value end
            if not worst or rec.value < worst then worst = rec.value end
        end
    end
    local winners, lows = {}, {}
    for _, i in ipairs(self:RoundPlayers()) do
        local rec = c.reveals[r][i]
        if rec and rec.value == best then winners[#winners + 1] = i end
        if rec and rec.value == worst then lows[#lows + 1] = i end
    end
    local scores = {}
    for i, p in ipairs(c.players) do scores[i] = p.score end
    for _, i in ipairs(winners) do scores[i] = scores[i] + 1 end
    -- the lowest calls next; among equals the one with fewer points, then chance
    local low = math.huge
    for _, i in ipairs(lows) do if scores[i] < low then low = scores[i] end end
    local cand = {}
    for _, i in ipairs(lows) do if scores[i] == low then cand[#cand + 1] = i end end
    local nextCaller = cand[math.random(1, math.max(1, #cand))] or c.caller
    -- after the fifth round: a single leader wins, equal leaders play on while values are left
    local nextRound, only, final = r + 1, nil, false
    local active = {}
    for i, p in ipairs(c.players) do if not p.left then active[#active + 1] = i end end
    if #active < 2 then
        final = true
    elseif r >= self.ROUNDS then
        local top = -1
        for _, i in ipairs(active) do if scores[i] > top then top = scores[i] end end
        local leaders = {}
        for _, i in ipairs(active) do if scores[i] == top then leaders[#leaders + 1] = i end end
        if #leaders < 2 or #self:FreeStats() == 0 then
            final = true
        else
            only = leaders
            nextCaller = leaders[1]
            for _, i in ipairs(leaders) do if i == 1 then nextCaller = 1 end end
        end
    end
    local onlyText = ""
    if only then
        local parts = {}
        for _, i in ipairs(only) do parts[#parts + 1] = tostring(i) end
        onlyText = table.concat(parts, ",")
    end
    local wtext, stext = {}, {}
    for _, i in ipairs(winners) do wtext[#wtext + 1] = tostring(i) end
    for i = 1, #c.players do stext[i] = tostring(scores[i]) end
    local left = {}
    for i, p in ipairs(c.players) do if p.left then left[#left + 1] = tostring(i) end end
    local fields = { c.id, r, table.concat(wtext, ","), nextCaller, table.concat(stext, ","), final and 1 or 0, onlyText, table.concat(left, ",") }
    out("MW", unpack(fields))
    self:OnResult(fields)
end

-- the result of a round, from the host
function M:OnResult(f)
    local c = self.cur
    local r = tonumber(f[2])
    if not c or not r or r ~= c.round then return end
    local winners = {}
    for _, s in ipairs(split(f[3])) do winners[tonumber(s)] = true end
    local scores = split(f[5])
    for i, p in ipairs(c.players) do p.score = tonumber(scores[i]) or p.score end
    for _, s in ipairs(split(f[8])) do local p = c.players[tonumber(s)]; if p then p.left = true end end
    local only = nil
    if f[7] and f[7] ~= "" then
        only = {}
        for _, s in ipairs(split(f[7])) do only[tonumber(s)] = true end
    end
    c.results[r] = { winners = winners, caller = tonumber(f[4]), final = tostring(f[6]) == "1", only = only, stat = c.stat }
    if r == self.ROUNDS then c.regular = c.players[c.me].score end
    -- luck: a round won with a foe killed only once
    local mine = c.reveals[r][c.me]
    if winners[c.me] and mine and mine.kills == 1 then local rec = self:Record(); if rec then rec.lucky = (rec.lucky or 0) + 1 end end
    c.phase = "result"
    c.deadline = now() + self.REVEAL_HOLD
    c.heard = now()
    note("result")
    changed()
end

-- after the reveal: the next round or the end
function M:Advance()
    local c = self.cur
    local res = c.results[c.round]
    if res.final then self:Finish(); return end
    c.revealedAt, c.stat = nil, nil
    local nextOnly = res.only or c.only
    self:Begin(c.round + 1, res.caller, nextOnly)
end

function M:Leaders()
    local c = self.cur
    local top, list = -1, {}
    for pass = 1, 2 do
        for i, p in ipairs(c.players) do
            if not p.left or pass == 2 then
                if p.score > top then top, list = p.score, { i } elseif p.score == top then list[#list + 1] = i end
            end
        end
        if #list > 0 then break end
    end
    return list, top
end

function M:Finish()
    local c = self.cur
    c.phase = "done"
    c.deadline = nil
    local leaders = self:Leaders()
    local won = false
    for _, i in ipairs(leaders) do if i == c.me then won = true end end
    c.won = won
    local rec = self:Record()
    if rec and not c.demo then
        rec.n = rec.n + 1
        if won then rec.w = rec.w + 1 end
        if won and #leaders == 1 and c.round > self.ROUNDS then rec.sd = rec.sd + 1 end
        if (c.regular or 0) >= self.ROUNDS then rec.perfect = rec.perfect + 1 end
        if c.players[c.me].score == 0 then rec.zero = rec.zero + 1 end
        if won and #c.players >= self.MAX_PLAYERS then rec.full = rec.full + 1 end
        local count = 0
        for _ in pairs(rec.rivals) do count = count + 1 end
        for i, p in ipairs(c.players) do
            if i ~= c.me then
                if rec.rivals[p.guid] then rec.rivals[p.guid].n = rec.rivals[p.guid].n + 1
                elseif count < self.MAX_RIVALS then rec.rivals[p.guid] = { n = 1, nm = p.name }; count = count + 1 end
            end
        end
        if L and L.SafeCheck then L:SafeCheck() end
    end
    note("finish")
    changed()
end

-- I close the window: out of the match
function M:Leave()
    local c = self.cur
    if not c then return end
    if c.phase ~= "done" then
        if c.phase == "invite" then out("MX", c.id) else out("MQ", c.id, c.me) end
        note("leave")
    end
    self.cur = nil
    changed()
end

----------------------------------------------------------------------
-- Messages from the others
----------------------------------------------------------------------
local function mine(f)
    local c = M.cur
    return c and c.id == f[1]
end

local function onPicked(f)
    if not mine(f) then return end
    local c = M.cur
    local r, i = tonumber(f[2]), tonumber(f[3])
    if not r or not i or i == c.me then return end
    c.picks[r] = c.picks[r] or {}
    c.picks[r][i] = true
    c.heard = now()
    M:CheckPicks()
    changed()
end

local function onCalled(f)
    if not mine(f) then return end
    local c = M.cur
    local r, i, stat = tonumber(f[2]), tonumber(f[3]), f[4]
    if not r or i == c.me or not M.byStat[stat or ""] then return end
    c.heard = now()
    if r ~= c.round then c.calls[r] = stat; return end
    -- the call can arrive while I still pick: my time is up, I take one at random
    if c.phase == "pick" then M:Pick(math.random(1, #c.offers)) end
    M:OnCall(r, stat)
end

local function onRevealed(f)
    if not mine(f) then return end
    local c = M.cur
    local r, i = tonumber(f[2]), tonumber(f[3])
    if not r or not i or i == c.me then return end
    c.reveals[r] = c.reveals[r] or {}
    c.reveals[r][i] = { id = tonumber(f[4]), value = tonumber(f[5]) or 0, level = tonumber(f[6]) or 0, rank = f[7] or "normal",
                        type = f[8] or "none", name = f[9] or "?", zone = f[10] or "" }
    c.heard = now()
    M:CheckReveals()
    changed()
end

local function onRound(f)
    if not mine(f) or M:IsHost() then return end
    M:OnResult(f)
end

local function onQuit(f)
    if not mine(f) then return end
    local c = M.cur
    local i = tonumber(f[2])
    local p = i and c.players[i]
    if not p or i == c.me then return end
    p.left = true
    note("quit")
    if i == 1 then
        OMQ:Print(p.name .. " left, the duel is over")
        M:Finish()
        return
    end
    if M:IsHost() then
        local active = 0
        for _, q in ipairs(c.players) do if not q.left then active = active + 1 end end
        if active < 2 and c.phase ~= "done" then M:Finish(); out("MW", c.id, c.round, "", c.caller, "", 1, "", tostring(i)); return end
    end
    M:CheckPicks()
    M:CheckReveals()
    changed()
end

local function onCancel(f)
    local id = f[1]
    if M.invite and M.invite.id == id then M.invite = nil end
    if M.waiting and M.waiting.id == id then M.waiting = nil end
    if M.cur and M.cur.id == id and M.cur.phase ~= "done" then
        OMQ:Print("the duel was called off")
        M.cur = nil
    end
    changed()
end

OMQ:RegisterMessage("MI", onInvite)
OMQ:RegisterMessage("MJ", onAnswer)
OMQ:RegisterMessage("MS", onStart)
OMQ:RegisterMessage("MP", onPicked)
OMQ:RegisterMessage("MC", onCalled)
OMQ:RegisterMessage("MR", onRevealed)
OMQ:RegisterMessage("MW", onRound)
OMQ:RegisterMessage("MQ", onQuit)
OMQ:RegisterMessage("MX", onCancel)

----------------------------------------------------------------------
-- Demo dads: they pick, call and reveal from my own foes
----------------------------------------------------------------------
function M:BotsPick()
    local c = self.cur
    for i, p in ipairs(c.players) do
        if p.bot and self:InRound(i) then
            local r = c.round
            C_Timer.After(1 + math.random() * 3, function()
                if M.cur ~= c or c.round ~= r then return end
                c.picks[r][i] = true
                M:CheckPicks()
                changed()
            end)
        end
    end
end

function M:BotCall()
    local c = self.cur
    self:OnCall(c.round, randomFree())
end

function M:BotsReveal(round, stat)
    local c = self.cur
    local pool = self:Pool()
    for i, p in ipairs(c.players) do
        if p.bot and self:InRound(i) and #pool > 0 then
            local mob = self:Mob(pool[math.random(1, #pool)])
            if mob then
                c.reveals[round][i] = { id = mob.id, value = mob.vals[stat] or 0, level = mob.level, rank = mob.rank,
                                        type = mob.type, name = mob.name, zone = mob.zone or "", kills = mob.kills }
            end
        end
    end
end

----------------------------------------------------------------------
-- Clock: time limits of every step
----------------------------------------------------------------------
function M:Tick()
    local t = now()
    if self.invite and t > self.invite.deadline then
        self:Answer(false)
    end
    if self.waiting and t > self.waiting.deadline then self.waiting = nil end
    local c = self.cur
    if not c or c.phase == "done" then return end
    if c.phase == "invite" then
        if t > c.deadline then startMatch() end
        return
    end
    if c.phase == "pick" and t > c.phaseAt + self.PICK_TIME then
        self:Pick(math.random(1, #c.offers))
        note("autopick")
    elseif c.phase == "picked" or c.phase == "watch" then
        self:CheckPicks()
        -- the caller is gone: the host names a value
        if c.callAt and self:IsHost() and not c.calls[c.round] and t > c.callAt + self.CALL_TIME + self.GRACE then
            local stat = randomFree()
            out("MC", c.id, c.round, c.me, stat)
            self:OnCall(c.round, stat)
            note("hostcall")
        end
    elseif c.phase == "call" then
        if c.caller == c.me and t > c.callAt + self.CALL_TIME then
            self:Call(randomFree())
            note("autocall")
        elseif self:IsHost() and c.caller ~= c.me and not c.calls[c.round] and t > c.callAt + self.CALL_TIME + self.GRACE then
            local stat = randomFree()
            out("MC", c.id, c.round, c.me, stat)
            self:OnCall(c.round, stat)
            note("hostcall")
        end
    elseif c.phase == "reveal" then
        self:CheckReveals()
    elseif c.phase == "result" and t > c.deadline then
        self:Advance()
    end
    -- no word from the others for a long time: over
    if self.cur == c and not c.demo and c.phase ~= "done" and t > (c.heard or t) + self.LOST_AFTER then
        OMQ:Print("the duel ended: no answer from the others")
        note("lost")
        self:Finish()
    end
    if self.cur and self.cur.phase ~= "done" then changed() end
end

OMQ:On("READY", function()
    C_Timer.NewTicker(1, function()
        local fine, err = pcall(M.Tick, M)
        if not fine then note("err.tick"); OMQ:Error("match tick", err) end
    end)
end)

----------------------------------------------------------------------
-- The duels tab and its entries in the ledger
----------------------------------------------------------------------
if L then
    local pos = #L.TABS + 1
    for i, t in ipairs(L.TABS) do if t.id == "summary" then pos = i end end
    table.insert(L.TABS, pos, { id = "duels", name = "Duels" })
    local I = "Interface\\Icons\\"
    local function add(c)
        c.tab = "duels"
        c.icon = I .. c.icon
        c.need = c.need or (not c.tiers and 1 or nil)
        c.start = c.tiers and (c.start or 2) or nil
        L.CARDS[#L.CARDS + 1] = c
        L.byId[c.id] = c
    end
    local function rec(b) return b.match or {} end
    add({ id = "duel20", title = "Ready to Duel", text = "Reach level " .. M.MIN_LEVEL, icon = "Ability_Warrior_Challange", q = 1,
          value = function(_, ctx) return ctx.level end, need = M.MIN_LEVEL })
    add({ id = "duel1", title = "First Challenge", text = "Play your first duel", icon = "INV_Sword_04", q = 2,
          value = function(b) return rec(b).n or 0 end })
    add({ id = "duelwin", title = "Duelist", text = "Win %s duels", icon = "INV_Sword_27", tiers = { 3, 10, 25, 50 },
          value = function(b) return rec(b).w or 0 end })
    add({ id = "duelplay", title = "Arena Regular", text = "Play %s duels", icon = "INV_Misc_Ticket_Tarot_Stack_01", tiers = { 10, 25, 50 },
          value = function(b) return rec(b).n or 0 end })
    add({ id = "duel5", title = "Clean Sheet", text = "Win all five rounds of a duel", icon = "INV_Crown_01", q = 4,
          value = function(b) return rec(b).perfect or 0 end })
    add({ id = "duelsd", title = "Nerves of Steel", text = "Win a duel in extra rounds", icon = "Spell_Nature_Lightning", q = 4,
          value = function(b) return rec(b).sd or 0 end })
    add({ id = "duelfull", title = "Packed Arena", text = "Win a duel against four dads", icon = "Ability_Warrior_RallyingCry", q = 4,
          value = function(b) return rec(b).full or 0 end })
    add({ id = "duellucky", title = "Lucky Shot", text = "Win a round with a foe you killed only once", icon = "INV_Misc_Dice_01", q = 3,
          value = function(b) return rec(b).lucky or 0 end })
    add({ id = "duelrival", title = "Arch Rival", text = "Play 10 duels against the same dad", icon = "Ability_Warrior_Revenge", q = 3, need = 10,
          value = function(b)
              local best, who = 0, nil
              for _, r in pairs(rec(b).rivals or {}) do if (r.n or 0) > best then best, who = r.n, r.nm end end
              return best, who
          end })
    add({ id = "duelzero", title = "Swept", text = "End a duel without a single point", icon = "INV_Misc_Bone_HumanSkull_01", q = 2,
          value = function(b) return rec(b).zero or 0 end })
end
