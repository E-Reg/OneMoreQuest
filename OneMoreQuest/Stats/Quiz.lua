-- One More Quest: flight quiz (from the first flight, inside the ledger)
-- On every flight path the player is asked whether to play. Five questions about the own character, drawn from
-- the counters of Stats/Tally.lua and Stats/Haul.lua; each answer is revealed at once. Only questions with exactly
-- one right answer are asked, each kind at most once per flight. No answer, or "Not now": nothing is counted.
-- A landing before the fifth answer drops the rest; such a flight does not count for 5/5 or 0/5.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local Q = {}
OMQ.Quiz = Q
local L = OMQ.Ledger

Q.QUESTIONS = 5
Q.INVITE_TIME = 15
Q.CLOSE_TIME = 15
Q.NEXT_TIME = 10
Q.STREAK_CARD = 10

local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function str(v) return type(v) == "string" and ok(v) and v ~= "" end
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2)
end
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
local function shuffle(t)
    for i = #t, 2, -1 do local j = math.random(1, i); t[i], t[j] = t[j], t[i] end
    return t
end

Q.diag = {}
local function note(k) Q.diag[k] = (Q.diag[k] or 0) + 1 end

----------------------------------------------------------------------
-- Names and texts
----------------------------------------------------------------------
local I = "Interface\\Icons\\"
local function mapName(id)
    if not num(id) or not (C_Map and C_Map.GetMapInfo) then return nil end
    local info = call(C_Map.GetMapInfo, id)
    return info and str(info.name) and info.name or nil
end
local function spellName(id)
    local n = C_Spell and C_Spell.GetSpellName and call(C_Spell.GetSpellName, id)
    if not str(n) and GetSpellInfo then n = call(GetSpellInfo, id) end
    return str(n) and n or nil
end
local function spellIcon(id)
    local t = C_Spell and C_Spell.GetSpellTexture and call(C_Spell.GetSpellTexture, id)
    if not ok(t) and GetSpellTexture then t = call(GetSpellTexture, id) end
    return ok(t) and t or nil
end
local function itemIcon(id)
    local t = C_Item and C_Item.GetItemIconByID and call(C_Item.GetItemIconByID, id)
    if not ok(t) and GetItemIcon then t = call(GetItemIcon, id) end
    return ok(t) and t or nil
end
local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end
local function money(c)
    c = math.floor(c or 0)
    if c >= 10000 then return math.floor(c / 10000) .. "g" end
    return math.floor(c / 100) .. "s"
end
local function playTime(s)
    s = math.floor(s or 0)
    local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return m .. " min"
end
Q.Money, Q.PlayTime = money, playTime

local SOURCE = { drop = "Dropped by a foe", boss = "Boss loot", chest = "From a chest", container = "From a container",
                 fish = "Fishing", roll = "Won a roll", quest = "Quest reward", vendor = "Bought", mail = "By mail", craft = "Crafted" }
local ROLL = { need = "Need", greed = "Greed", pass = "Pass", de = "Disenchant" }
local TYPE_NAME = { beast = "Beasts", humanoid = "Humanoids", undead = "Undead", demon = "Demons", elemental = "Elementals",
                    dragonkin = "Dragonkin", giant = "Giants", mechanical = "Mechanicals", critter = "Critters", aberration = "Aberrations" }
local GATHER = { herb = "Herbs", mine = "Ore", skin = "Skins", fish = "Fish" }
local CAUSE = { fall = "Falling", drown = "Drowning", lava = "Lava", player = "Another player" }

----------------------------------------------------------------------
-- Pools from the book
----------------------------------------------------------------------
-- foes with a name: { label, model, value fields }
local function mobs(b, filter)
    local out = {}
    for id, n in pairs(b.kills and b.kills.npc or {}) do
        if type(n) == "table" and str(n.nm) and (not filter or filter(n)) then
            out[#out + 1] = { label = n.nm, model = id, n = n.n or 0, t = n.t, lt = n.lt, zn = n.zn, rk = n.rk, id = id }
        end
    end
    return out
end
local function causeOf(b, d)
    if not d then return nil end
    if d.why == "npc" and d.id then
        local n = b.kills and b.kills.npc and b.kills.npc[d.id]
        return n and str(n.nm) and n.nm or nil, d.id
    end
    return CAUSE[d.why]
end
local function causes(b)
    local per, model = {}, {}
    for _, d in ipairs(b.deaths or {}) do
        local c, id = causeOf(b, d)
        if c then per[c] = (per[c] or 0) + 1; model[c] = id end
    end
    local out = {}
    for c, n in pairs(per) do out[#out + 1] = { label = c, n = n, model = model[c] } end
    return out
end
local function gear(b, filter)
    local out = {}
    for _, e in pairs(b.gear or {}) do
        if str(e.nm) and (e.q or 0) >= 1 and (not filter or filter(e)) then
            out[#out + 1] = { label = e.nm, icon = itemIcon(e.id), e = e, t = e.t, wd = e.wd, wl = e.wl }
        end
    end
    return out
end
local function zoneNames(b, skip)
    local out, seen = {}, {}
    for id, z in pairs(b.zones or {}) do
        local nm = mapName(id)
        if nm and not seen[nm] and nm ~= skip then seen[nm] = true; out[#out + 1] = { label = nm, t = z.t, lt = z.lt, id = id } end
    end
    return out
end

----------------------------------------------------------------------
-- Building a question
----------------------------------------------------------------------
-- four (or `n`) entries of the pool whose `key` has one strict best (highest, or lowest with low = true)
local function pickBest(pool, key, low, n)
    n = n or 4
    local usable = {}
    for _, p in ipairs(pool) do if p[key] ~= nil then usable[#usable + 1] = p end end
    if #usable < n then return nil end
    for _ = 1, 12 do
        shuffle(usable)
        local opts, best, bestN = {}, nil, 0
        for i = 1, n do opts[i] = usable[i] end
        for i, o in ipairs(opts) do
            local v = o[key]
            if best == nil or (low and v < opts[best][key]) or (not low and v > opts[best][key]) then best, bestN = i, 1
            elseif v == opts[best][key] then bestN = bestN + 1 end
        end
        if bestN == 1 then return opts, best end
    end
    return nil
end
Q._PickBest = pickBest

-- the right number and three others around it, no doubles, none below `min`
local function numbers(v, small)
    if not num(v) then return nil end
    local cand = small and { v - 2, v - 1, v + 1, v + 2, v + 3 }
        or { math.floor(v * 0.5 + 0.5), math.floor(v * 0.75 + 0.5), math.floor(v * 1.35 + 0.5), math.floor(v * 1.7 + 0.5), v + 2 }
    local list, seen = { v }, { [v] = true }
    shuffle(cand)
    for _, c in ipairs(cand) do
        if #list < 4 and c >= (small and 1 or 0) and not seen[c] then seen[c] = true; list[#list + 1] = c end
    end
    if #list < 4 then return nil end
    shuffle(list)
    for i, x in ipairs(list) do if x == v then return list, i end end
end
Q._Numbers = numbers

local function numberQ(kind, text, v, fmt, reveal, extra)
    local list, right = numbers(v, extra and extra.small)
    if not list then return nil end
    local opts = {}
    for i, x in ipairs(list) do opts[i] = { label = fmt and fmt(x) or tostring(x) } end
    return { kind = kind, text = text, options = opts, right = right, reveal = reveal, model = extra and extra.model,
             icon = extra and extra.icon, numbers = true }
end
-- a question over picked options: `sub(o)` is what each option shows after the answer
local function bestQ(kind, text, pool, key, low, sub, reveal, n)
    local opts, right = pickBest(pool, key, low, n)
    if not opts then return nil end
    local out = {}
    for i, o in ipairs(opts) do out[i] = { label = o.label, model = o.model, icon = o.icon, sub = sub and sub(o) or nil } end
    return { kind = kind, text = text, options = out, right = right, reveal = reveal and reveal(opts[right]) or nil }
end
-- one right label and up to three others from a list of labels
local function labelQ(kind, text, right, others, reveal, extra)
    local list, seen = { right }, { [right] = true }
    shuffle(others)
    for _, o in ipairs(others) do
        if #list < 4 and o and not seen[o] then seen[o] = true; list[#list + 1] = o end
    end
    if #list < 2 then return nil end
    shuffle(list)
    local opts, idx = {}, nil
    for i, l in ipairs(list) do opts[i] = { label = l }; if l == right then idx = i end end
    return { kind = kind, text = text, options = opts, right = idx, reveal = reveal, model = extra and extra.model, icon = extra and extra.icon }
end
local function ago(t)
    if not num(t) then return "" end
    local d = math.floor((time() - t) / 86400)
    if d <= 0 then return "today" elseif d == 1 then return "yesterday" end
    return d .. " days ago"
end

----------------------------------------------------------------------
-- The catalog (ids as in the plan: A1 to A37 without the old A22)
----------------------------------------------------------------------
Q.KINDS = {}
local function kind(id, fn) Q.KINDS[#Q.KINDS + 1] = { id = id, fn = fn } end

kind("A1", function(b) return bestQ("A1", "Which of these have you killed most often?", mobs(b), "n", false,
    function(o) return plural(o.n, "kill", "kills") end, function(o) return o.label .. ": " .. plural(o.n, "kill", "kills") .. "." end) end)
kind("A2", function(b)
    local pool = mobs(b, function(n) return (n.n or 0) >= 4 end)
    if #pool == 0 then return nil end
    local m = pool[math.random(1, #pool)]
    return numberQ("A2", "How many " .. m.label .. " have you killed?", m.n, nil, plural(m.n, "kill", "kills") .. " so far.", { model = m.model })
end)
kind("A3", function(b)
    local pool = {}
    for k, p in pairs(b.kills and b.kills.type or {}) do
        if TYPE_NAME[k] and (p.n or 0) > 0 then pool[#pool + 1] = { label = TYPE_NAME[k], n = p.n } end
    end
    if #pool < 2 then return nil end
    return bestQ("A3", "Which kind of foe have you killed most?", pool, "n", false,
        function(o) return plural(o.n, "kill", "kills") end, function(o) return o.label .. ": " .. o.n .. "." end, math.min(4, #pool))
end)
kind("A4", function(b) return bestQ("A4", "Which of these did you kill first?", mobs(b), "t", true,
    function(o) return ago(o.t) end, function(o) return o.label .. ", " .. ago(o.t) .. "." end) end)
kind("A5", function(b)
    local pool = mobs(b, function(n) return n.zn ~= nil end)
    if #pool == 0 then return nil end
    local m = pool[math.random(1, #pool)]
    local right = mapName(m.zn)
    if not right then return nil end
    local others = {}
    for _, z in ipairs(zoneNames(b, right)) do others[#others + 1] = z.label end
    if #others < 3 then return nil end
    return labelQ("A5", "Where did you kill your first " .. m.label .. "?", right, others, "In " .. right .. ".", { model = m.model })
end)
kind("A6", function(b)
    local f = b.firsts and b.firsts.elite
    if not (f and num(f.l)) then return nil end
    return numberQ("A6", "At what level did you kill your first elite?", f.l, function(x) return "Level " .. x end,
        "At level " .. f.l .. ".", { small = true })
end)
kind("A7", function(b)
    local pool = causes(b)
    if #pool < 2 then return nil end
    return bestQ("A7", "What killed you most often?", pool, "n", false,
        function(o) return plural(o.n, "death", "deaths") end, function(o) return o.label .. ": " .. plural(o.n, "time", "times") .. "." end,
        math.min(4, #pool))
end)
local function deathZone(kind, text, b, d)
    local m = d and d.m
    local zone = m and OMQ.Tally.ZoneOf and OMQ.Tally.ZoneOf(m) or m
    local right = mapName(zone) or mapName(m)
    if not right then return nil end
    local others = {}
    for _, z in ipairs(zoneNames(b, right)) do others[#others + 1] = z.label end
    if #others < 3 then return nil end
    return labelQ(kind, text, right, others, "In " .. right .. ".")
end
kind("A8", function(b) return deathZone("A8", "Where did you die for the first time?", b, (b.deaths or {})[1]) end)
kind("A9", function(b)
    local n = #(b.deaths or {})
    if n < 4 then return nil end
    return numberQ("A9", "How often have you died?", n, nil, plural(n, "death", "deaths") .. ".")
end)
kind("A10", function(b) return bestQ("A10", "Which of these did you find first?", gear(b, function(e) return e.src ~= "before" end), "t", true,
    function(o) return ago(o.t) end, function(o) return o.label .. ", " .. ago(o.t) .. "." end) end)
kind("A11", function(b)
    local pool = gear(b, function(e) return SOURCE[e.src or ""] ~= nil end)
    if #pool == 0 then return nil end
    local g = pool[math.random(1, #pool)]
    local others = {}
    for k, v in pairs(SOURCE) do if k ~= g.e.src then others[#others + 1] = v end end
    return labelQ("A11", "Where did " .. g.label .. " come from?", SOURCE[g.e.src], others, SOURCE[g.e.src] .. ".", { icon = g.icon })
end)
kind("A12", function(b) return bestQ("A12", "Which of these did you wear on the most days?", gear(b, function(e) return (e.wd or 0) > 0 end), "wd", false,
    function(o) return plural(o.wd, "day", "days") end, function(o) return o.label .. ": " .. plural(o.wd, "day", "days") .. "." end) end)
kind("A13", function(b)
    local n = b.loot and b.loot[2] or 0
    if n < 4 then return nil end
    return numberQ("A13", "How many green items have you looted?", n, nil, plural(n, "green item", "green items") .. ".")
end)
kind("A14", function(b)
    local list = {}
    for _, r in ipairs(b.rolls or {}) do if str(r.nm) and ROLL[r.c] then list[#list + 1] = r end end
    if #list == 0 then return nil end
    local r = list[math.random(1, #list)]
    local others = { "Need", "Greed", "Pass" }
    if r.c == "de" then others[#others + 1] = "Disenchant" end
    return labelQ("A14", "What did you roll on " .. r.nm .. "?", ROLL[r.c], others,
        ROLL[r.c] .. (r.w and ", and you won it." or "."), { icon = itemIcon(r.id) })
end)
kind("A15", function(b)
    local pool, seen = {}, {}
    for id, m in pairs(b.maps or {}) do
        local nm = mapName(id)
        if nm and not seen[nm] and (m.s or 0) > 0 then seen[nm] = true; pool[#pool + 1] = { label = nm, s = m.s } end
    end
    return bestQ("A15", "In which of these places did you spend the most time?", pool, "s", false,
        function(o) return playTime(o.s) end, function(o) return o.label .. ": " .. playTime(o.s) .. "." end)
end)
kind("A16", function(b)
    local n = b.move and b.move.jumps or 0
    if n < 4 then return nil end
    return numberQ("A16", "How often have you jumped?", n, nil, plural(n, "jump", "jumps") .. ".")
end)
kind("A17", function(b)
    local n = math.floor((b.afk or 0) / 60)
    if n < 4 then return nil end
    return numberQ("A17", "How many minutes have you been away (AFK)?", n, function(x) return x .. " min" end, n .. " minutes.")
end)
kind("A18", function(b)
    local c = b.money and b.money.repair or 0
    local unit = c >= 10000 and 10000 or 100
    local v = math.floor(c / unit)
    if v < 4 then return nil end
    local fmt = function(x) return x .. (unit == 10000 and "g" or "s") end
    return numberQ("A18", "How much have you spent on repairs?", v, fmt, fmt(v) .. " so far.")
end)
kind("A19", function(b)
    local n = count(b.quests)
    if n < 4 then return nil end
    return numberQ("A19", "How many quests have you turned in?", n, nil, plural(n, "quest", "quests") .. ".")
end)
local function spells(b, field)
    local out = {}
    for id, v in pairs(b[field] or {}) do
        local nm = num(id) and spellName(id)
        if nm then out[#out + 1] = { label = nm, icon = spellIcon(id), v = v, n = (b.spells or {})[id] or 0 } end
    end
    return out
end
kind("A20", function(b) return bestQ("A20", "Which of your spells have you cast most often?", spells(b, "spells"), "v", false,
    function(o) return plural(o.v, "cast", "casts") end, function(o) return o.label .. ": " .. plural(o.v, "cast", "casts") .. "." end) end)
kind("A21", function(b)
    local pool = {}  -- up to four kinds
    for k, label in pairs(GATHER) do
        local n = b.gather and b.gather[k] or 0
        if n > 0 then pool[#pool + 1] = { label = label, n = n } end
    end
    if #pool < 2 then return nil end
    return bestQ("A21", "What have you gathered most often?", pool, "n", false,
        function(o) return tostring(o.n) end, function(o) return o.label .. ": " .. o.n .. "." end, math.min(4, #pool))
end)
kind("A22", function(b)
    local list = {}
    for l, e in pairs(b.levels or {}) do
        local p = b.levels[l - 1]
        if p and num(e.secs) and num(p.secs) and e.secs - p.secs >= 240 then list[#list + 1] = { l = l, s = e.secs - p.secs } end
    end
    if #list == 0 then return nil end
    local x = list[math.random(1, #list)]
    local mins = math.floor(x.s / 60)
    return numberQ("A22", "How long did level " .. x.l .. " take you (play time)?", mins, function(m) return playTime(m * 60) end,
        playTime(mins * 60) .. " of play.")
end)
kind("A23", function(b)
    local ev = {}
    local function add(label, t) if num(t) then ev[#ev + 1] = { label = label, t = t } end end
    local f = b.firsts or {}
    add("Your first elite kill", f.elite and f.elite.t)
    add("Your first rare kill", f.rare and f.rare.t)
    add("Your first blue item", f.blue and f.blue.t)
    add("Your first dungeon", f.dungeon and f.dungeon.t)
    add("Your first death", (b.deaths or {})[1] and b.deaths[1].t)
    for l, e in pairs(b.levels or {}) do if l % 5 == 0 then add("Reaching level " .. l, e.t) end end
    return bestQ("A23", "What came first?", ev, "t", true, function(o) return ago(o.t) end,
        function(o) return o.label .. ", " .. ago(o.t) .. "." end, 2)
end)
kind("A24", function(b)
    local n = b.prof and b.prof.crafted or 0
    if n < 4 then return nil end
    return numberQ("A24", "How many items have you crafted?", n, nil, plural(n, "item", "items") .. ".")
end)
local function crafts(b)
    local out = {}
    for id, c in pairs(b.craft or {}) do
        if str(c.nm) then out[#out + 1] = { label = c.nm, icon = itemIcon(id), n = c.n or 0, lt = c.lt } end
    end
    return out
end
kind("A25", function(b) return bestQ("A25", "Which of these have you crafted most often?", crafts(b), "n", false,
    function(o) return plural(o.n, "time", "times") end, function(o) return o.label .. ": " .. plural(o.n, "time", "times") .. "." end) end)
kind("A26", function(b) return bestQ("A26", "Which of these did you craft last?", crafts(b), "lt", false,
    function(o) return ago(o.lt) end, function(o) return o.label .. ", " .. ago(o.lt) .. "." end) end)
kind("A27", function(b) return bestQ("A27", "Which of these did you kill last?", mobs(b), "lt", false,
    function(o) return ago(o.lt) end, function(o) return o.label .. ", " .. ago(o.lt) .. "." end) end)
kind("A28", function(b) return bestQ("A28", "Which of these elites did you kill last?",
    mobs(b, function(n) return n.rk == "elite" or n.rk == "rareelite" end), "lt", false,
    function(o) return ago(o.lt) end, function(o) return o.label .. ", " .. ago(o.lt) .. "." end) end)
kind("A29", function(b)
    local d = (b.deaths or {})[#(b.deaths or {})]
    local right, model = causeOf(b, d)
    if not right then return nil end
    local others = {}
    for _, c in ipairs(causes(b)) do others[#others + 1] = c.label end
    for _, m in ipairs(mobs(b)) do others[#others + 1] = m.label end
    return labelQ("A29", "What killed you last?", right, others, right .. ", " .. ago(d.t) .. ".", { model = model })
end)
kind("A30", function(b) local d = b.deaths or {}; return deathZone("A30", "Where did you die last?", b, d[#d]) end)
kind("A31", function(b)
    local d = (b.deaths or {})[#(b.deaths or {})]
    if not (d and num(d.l)) then return nil end
    return numberQ("A31", "At what level did you die last?", d.l, function(x) return "Level " .. x end, "At level " .. d.l .. ".", { small = true })
end)
kind("A32", function(b) return bestQ("A32", "Which of these did you find last?", gear(b, function(e) return e.src ~= "before" end), "t", false,
    function(o) return ago(o.t) end, function(o) return o.label .. ", " .. ago(o.t) .. "." end) end)
kind("A33", function(b) return bestQ("A33", "Which of these did you wear last?", gear(b, function(e) return str(e.wl) end), "wl", false,
    function(o) return o.wl end, function(o) return o.label .. ", last worn " .. o.wl .. "." end) end)
kind("A34", function(b)
    local last
    for _, e in pairs(b.gear or {}) do
        if e.q == 3 and num(e.l) and e.src ~= "before" and (not last or e.t > last.t) then last = e end
    end
    if not last then return nil end
    return numberQ("A34", "At what level did you find your last blue item?", last.l, function(x) return "Level " .. x end,
        (last.nm or "It") .. ", at level " .. last.l .. ".", { small = true, icon = itemIcon(last.id) })
end)
kind("A35", function(b)
    local here = OMQ.Tally.map and OMQ.Tally.ZoneOf and OMQ.Tally.ZoneOf(OMQ.Tally.map)
    return bestQ("A35", "Which of these zones did you visit last (before this one)?", zoneNames(b, mapName(here)), "lt", false,
        function(o) return ago(o.lt) end, function(o) return o.label .. ", " .. ago(o.lt) .. "." end)
end)
kind("A36", function(b)
    local pool = {}
    for id, n in pairs(b.npcs or {}) do
        if str(n.nm) and num(n.lt) then pool[#pool + 1] = { label = n.nm, model = id, lt = n.lt } end
    end
    return bestQ("A36", "Who of these did you talk to last?", pool, "lt", false,
        function(o) return ago(o.lt) end, function(o) return o.label .. ", " .. ago(o.lt) .. "." end)
end)
kind("A37", function(b) return bestQ("A37", "Which of these spells did you cast longest ago?", spells(b, "spellLast"), "v", true,
    function(o) return ago(o.v) end, function(o) return o.label .. ", " .. ago(o.v) .. "." end) end)

-- every question that can be asked now, each kind once, in random order (at most `n`)
function Q:Draw(b, n)
    b = b or self:Book()
    if not b then return {} end
    local kinds = {}
    for i, k in ipairs(self.KINDS) do kinds[i] = k end
    shuffle(kinds)
    local out = {}
    for _, k in ipairs(kinds) do
        if #out >= (n or self.QUESTIONS) then break end
        local fine, q = pcall(k.fn, b)
        if not fine then note("err." .. k.id) end
        if fine and q and q.right and #q.options >= 2 then out[#out + 1] = q end
    end
    return out
end
function Q:Possible(b)
    b = b or self:Book()
    local list = {}
    for _, k in ipairs(self.KINDS) do
        local fine, q = pcall(k.fn, b)
        if fine and q and q.right then list[#list + 1] = k.id end
    end
    return list
end

----------------------------------------------------------------------
-- Record and the run of one flight
----------------------------------------------------------------------
function Q:Book() return OMQ.Tally and OMQ.Tally.Book() end
function Q:Record()
    local b = self:Book()
    if not b then return nil end
    b.quiz = b.quiz or { n = 0, r = 0, streak = 0, best = 0, flights = 0, perfect = 0, zero = 0, asked = 0, played = 0 }
    return b.quiz
end

-- run: { phase = "invite" | "question" | "answered" | "done" | "landed", list, i, right, answered, choice, until }
function Q:Invite(demo)
    local b = self:Book()
    if not b or self.run then return nil end
    local list = self:Draw(b)
    -- from level 30 the invitation also offers Spell Rhythm, so it comes even without enough questions
    local rhythm = OMQ.Rhythm and OMQ.Rhythm:Unlocked() and not OMQ.Rhythm.run or false
    local short = #list < self.QUESTIONS
    if short and not rhythm then note("invite.short"); return nil end
    local rec = self:Record()
    rec.asked = rec.asked + 1
    self.run = { phase = "invite", list = list, i = 0, right = 0, answered = 0, demo = demo, at = GetTime(), rhythm = rhythm, short = short }
    note("invite")
    OMQ:Fire("QUIZ_CHANGED")
    return self.run
end
function Q:Decline()
    if not self.run then return end
    note(self.run.phase == "invite" and "declined" or "closed")
    self.run = nil
    OMQ:Fire("QUIZ_CHANGED")
end
function Q:Play()
    local r = self.run
    if not r or r.phase ~= "invite" or r.short then return end
    self:Record().played = self:Record().played + 1
    r.i, r.phase = 1, "question"
    note("play")
    OMQ:Fire("QUIZ_CHANGED")
end
-- the second button of the invitation from level 30: the quiz goes away, Spell Rhythm opens
function Q:Rhythm()
    local r = self.run
    if not r or r.phase ~= "invite" or not r.rhythm then return end
    note("rhythm")
    self.run = nil
    OMQ:Fire("QUIZ_CHANGED")
    OMQ.Rhythm:Open("flight")
end
function Q:Current() local r = self.run; return r and r.list[r.i] or nil end
function Q:Answer(choice)
    local r = self.run
    local q = self:Current()
    if not (r and q and r.phase == "question" and q.options[choice]) then return nil end
    local rec = self:Record()
    local right = choice == q.right
    r.choice, r.phase, r.answeredAt = choice, "answered", GetTime()
    r.answered = r.answered + 1
    r.results = r.results or {}
    r.results[r.answered] = right
    rec.n = rec.n + 1
    if right then
        r.right = r.right + 1
        rec.r = rec.r + 1
        rec.streak = rec.streak + 1
        if rec.streak > rec.best then rec.best = rec.streak end
    else
        rec.streak = 0
    end
    note(right and "right" or "wrong")
    if r.answered >= self.QUESTIONS then
        rec.flights = rec.flights + 1
        if r.right == self.QUESTIONS then rec.perfect = rec.perfect + 1 end
        if r.right == 0 then rec.zero = rec.zero + 1 end
        rec.last = time()
        r.full = true
    end
    OMQ:Fire("QUIZ_CHANGED")
    if L and L.SafeCheck and (r.full or rec.streak >= self.STREAK_CARD) then L:SafeCheck() end
    return right
end
function Q:Next()
    local r = self.run
    if not r or r.phase ~= "answered" then return end
    if r.i >= #r.list then r.phase, r.endAt = "done", GetTime() else r.i, r.phase, r.choice = r.i + 1, "question", nil end
    OMQ:Fire("QUIZ_CHANGED")
end
-- the landing: an open invitation goes away, a quiz with answers shows what was reached
function Q:Landed()
    local r = self.run
    if not r or r.demo then return end
    if r.phase == "invite" or r.answered == 0 then
        note("landed.empty")
        self.run = nil
    elseif r.phase ~= "done" and not r.full then
        r.phase, r.endAt = "landed", GetTime()
        note("landed.early")
    end
    OMQ:Fire("QUIZ_CHANGED")
end
function Q:Tick()
    local r = self.run
    if r and r.phase == "invite" and GetTime() - r.at >= self.INVITE_TIME then
        note("invite.timeout")
        self.run = nil
        OMQ:Fire("QUIZ_CHANGED")
    elseif r and r.phase == "answered" and GetTime() - (r.answeredAt or 0) >= self.NEXT_TIME then
        note("next.timeout")
        self:Next()
    elseif r and r.endAt and GetTime() - r.endAt >= self.CLOSE_TIME then
        note("closed.timeout")
        self.run = nil
        OMQ:Fire("QUIZ_CHANGED")
    end
    local taxi = UnitOnTaxi and call(UnitOnTaxi, "player") and true or false
    if taxi and not self.wasTaxi then self:Invite() elseif not taxi and self.wasTaxi then self:Landed() end
    self.wasTaxi = taxi
end

function Q:Diag()
    local rec = self:Record() or {}
    OMQ:Print(string.format("quiz: answered %d, right %d, streak %d (best %d), flights %d, 5/5 %d, 0/5 %d, asked %d, played %d",
        rec.n or 0, rec.r or 0, rec.streak or 0, rec.best or 0, rec.flights or 0, rec.perfect or 0, rec.zero or 0, rec.asked or 0, rec.played or 0))
    local list = self:Possible()
    print("  possible " .. #list .. ": " .. table.concat(list, " "))
    local keys = {}
    for k, v in pairs(self.diag) do keys[#keys + 1] = k .. "=" .. v end
    table.sort(keys)
    print("  diag " .. (#keys > 0 and table.concat(keys, " ") or "-"))
end

OMQ:RegisterCommand("quiz", function(arg)
    arg = (arg or ""):lower()
    if arg == "demo" then
        if Q.run then Q.run = nil end
        if not Q:Invite(true) then OMQ:Print("quiz: not enough questions yet (" .. #Q:Possible() .. " kinds)") end
    elseif arg == "land" then Q:Landed()
    else Q:Diag() end
end, nil, true)

OMQ:On("READY", function()
    C_Timer.NewTicker(1, function()
        local fine, err = pcall(Q.Tick, Q)
        if not fine then note("err.tick"); OMQ:Error("quiz tick", err) end
    end)
end)

----------------------------------------------------------------------
-- The quiz tab and its entries in the ledger
----------------------------------------------------------------------
if L then
    local pos = #L.TABS + 1
    for i, t in ipairs(L.TABS) do if t.id == "summary" then pos = i end end
    table.insert(L.TABS, pos, { id = "quiz", name = "Flight Quiz" })
    local function add(c)
        c.icon = I .. c.icon
        c.need = c.need or 1
        L.CARDS[#L.CARDS + 1] = c
        L.byId[c.id] = c
    end
    local function rec(b) return b.quiz or {} end
    add({ tab = "quiz", id = "quiz5", title = "Bullseye", text = "Answer all 5 questions right on one flight", icon = "Ability_Hunter_SniperShot", q = 3,
          value = function(b) return rec(b).perfect or 0 end })
    add({ tab = "quiz", id = "quizstreak", title = "Know-It-All Dad", text = "Answer 10 questions right in a row", icon = "INV_Misc_Book_07", q = 5,
          value = function(b) return rec(b).best or 0 end, need = Q.STREAK_CARD })
    add({ tab = "mishaps", id = "quiz0", title = "Blackout", text = "Answer no question right on a whole flight", icon = "Spell_Shadow_Charm", q = 2,
          value = function(b) return rec(b).zero or 0 end })
end
