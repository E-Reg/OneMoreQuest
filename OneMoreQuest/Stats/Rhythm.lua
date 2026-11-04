-- One More Quest: Spell Rhythm (from level 30, inside the ledger)
-- Pick one of four songs (Media\Track1-4.ogg, note times in Data/Beats.lua). After a countdown the song plays and
-- spell icons run on a timeline from right to left; the key bound to that spell must be pressed when the icon
-- crosses the hit zone. Spells come from the own action bars (only those with a keyboard key). While a song runs a
-- keyboard frame takes every key, so nothing is cast; the bindings themselves are never changed. Out of combat
-- only: combat, Esc or closing the window stops the song at once and gives the keys back.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local R = {}
OMQ.Rhythm = R
local L = OMQ.Ledger

R.MIN_LEVEL = 30
R.COUNTDOWN = 5
R.LOOK = 2.0          -- seconds an icon is on the timeline before it reaches the hit zone
R.PERFECT = 0.08      -- seconds off the beat for "perfect"
R.GOOD = 0.16         -- seconds off the beat for "good"; later is a miss
R.MODES = {
    { id = "easy", name = "Easy", n = 3 },
    { id = "medium", name = "Medium", n = 5 },
    { id = "hard", name = "Hard", n = 8 },
}
R.SPELLS = 8          -- the most a mode uses
R.POOL = 8            -- the spells of a run are drawn at random from the 8 most cast
R.CLOSE_TIME = 15
R.MEDIA = "Interface\\AddOns\\OneMoreQuest\\Media\\"
R.SONGS = {
    { id = "slow", name = "Slow Brain", file = "Track1.ogg", tempo = "Slow", icon = "Spell_Nature_Sleep" },
    { id = "medium", name = "Average Reaction", file = "Track2.ogg", tempo = "Medium", icon = "Ability_Mount_RidingHorse" },
    { id = "fast", name = "PhD Required", file = "Track3.ogg", tempo = "Fast", icon = "Spell_Nature_Lightning" },
    { id = "bonus", name = "Dad Mode", file = "Track4.ogg", tempo = "Bonus", icon = "Ability_Warrior_BattleShout" },
}
local I = "Interface\\Icons\\"

local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function str(v) return type(v) == "string" and ok(v) and v ~= "" end
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local res = { pcall(fn, ...) }
    if not res[1] then return nil end
    return unpack(res, 2)
end

R.diag = {}
local function note(k) R.diag[k] = (R.diag[k] or 0) + 1 end
local function now() return (GetTimePreciseSec and call(GetTimePreciseSec)) or GetTime() end
R.Now = now

----------------------------------------------------------------------
-- Spells on the action bars and the keys bound to them
----------------------------------------------------------------------
-- the action slot a binding command presses (Blizzard bars and Bartender4)
function R.SlotOf(cmd)
    if not str(cmd) then return nil end
    local n = cmd:match("^ACTIONBUTTON(%d+)$")
    if n then
        n = tonumber(n)
        local page = (GetActionBarPage and call(GetActionBarPage)) or 1
        local bonus = (GetBonusBarOffset and call(GetBonusBarOffset)) or 0
        if num(bonus) and bonus > 0 and page == 1 then page = 6 + bonus end
        return (page - 1) * 12 + n
    end
    local bar, b = cmd:match("^MULTIACTIONBAR(%d)BUTTON(%d+)$")
    if bar then
        local base = ({ [1] = 60, [2] = 48, [3] = 24, [4] = 36 })[tonumber(bar)]
        return base and base + tonumber(b) or nil
    end
    n = cmd:match("^CLICK BT4Button(%d+):")
    if n then return tonumber(n) end
    return nil
end

local function keyboardKey(k)
    return str(k) and not k:find("BUTTON") and not k:find("MOUSEWHEEL") and k ~= "ESCAPE"
end

-- only action bars 1, 2 and 3: the main bar (with its pages and stance bars), bottom left (61-72), bottom right (49-60)
function R.OnBars(cmd, slot)
    if not (str(cmd) and slot) then return false end
    if cmd:match("^ACTIONBUTTON%d+$") or cmd:match("^MULTIACTIONBAR[12]BUTTON%d+$") then return true end
    if cmd:match("^CLICK BT4Button") then return slot <= 12 or (slot >= 49 and slot <= 72) or slot >= 73 end
    return false
end

-- every spell with a keyboard key on bars 1-3: { id, name, icon, key, slot }, one per spell name and per key
function R:Spells()
    local out, names, keys = {}, {}, {}
    local n = GetNumBindings and call(GetNumBindings) or 0
    for i = 1, (num(n) and n or 0) do
        local cmd, _, k1, k2 = call(GetBinding, i)
        local slot = self.SlotOf(cmd)
        if not self.OnBars(cmd, slot) then slot = nil end
        local key = keyboardKey(k1) and k1 or (keyboardKey(k2) and k2 or nil)
        if slot and key and not keys[key] then
            local kind, id = call(GetActionInfo, slot)
            if kind == "spell" and num(id) then
                local name = (C_Spell and C_Spell.GetSpellName and call(C_Spell.GetSpellName, id)) or call(GetSpellInfo, id)
                local icon = call(GetActionTexture, slot) or (C_Spell and C_Spell.GetSpellTexture and call(C_Spell.GetSpellTexture, id))
                if str(name) and not names[name] then
                    names[name], keys[key] = true, true
                    out[#out + 1] = { id = id, name = name, icon = icon, key = key, slot = slot }
                end
            end
        end
    end
    return out
end

-- the keyed spells, the most cast first (casts of all ranks of a spell count together)
function R:Ranked()
    local list = self:Spells()
    local b = self:Book()
    local uses = {}
    for id, n in pairs(b and b.spells or {}) do
        local name = num(id) and ((C_Spell and C_Spell.GetSpellName and call(C_Spell.GetSpellName, id)) or call(GetSpellInfo, id))
        if str(name) and num(n) then uses[name] = (uses[name] or 0) + n end
    end
    for i, sp in ipairs(list) do sp.uses, sp.order = uses[sp.name] or 0, i end
    table.sort(list, function(a, c) if a.uses ~= c.uses then return a.uses > c.uses end return a.order < c.order end)
    return list
end
function R:Mode(id)
    for _, m in ipairs(self.MODES) do if m.id == id then return m end end
    return self.MODES[1]
end

-- the key text as the game writes it in the bindings: ALT-CTRL-SHIFT-X
function R.FullKey(key)
    local mods = ""
    if IsAltKeyDown and call(IsAltKeyDown) then mods = mods .. "ALT-" end
    if IsControlKeyDown and call(IsControlKeyDown) then mods = mods .. "CTRL-" end
    if IsShiftKeyDown and call(IsShiftKeyDown) then mods = mods .. "SHIFT-" end
    return mods .. key
end
-- the short form shown under an icon: S-1, C-Q, A-E
function R.ShortKey(key)
    return (tostring(key or ""):gsub("ALT%-", "A-"):gsub("CTRL%-", "C-"):gsub("SHIFT%-", "S-"))
end

----------------------------------------------------------------------
-- Record
----------------------------------------------------------------------
function R:Book() return OMQ.Tally and OMQ.Tally.Book() end
function R:Record()
    local b = self:Book()
    if not b then return nil end
    b.rhythm = b.rhythm or { plays = 0, done = 0, best = {}, full = 0, high = 0, low = 0 }
    b.rhythm.best = b.rhythm.best or {}
    for _, m in ipairs(self.MODES) do b.rhythm.best[m.id] = b.rhythm.best[m.id] or {} end
    return b.rhythm
end

function R:Unlocked()
    local level = UnitLevel and call(UnitLevel, "player")
    return num(level) and level >= self.MIN_LEVEL and self:Book() ~= nil or false
end

----------------------------------------------------------------------
-- Keys and game music while a song runs
----------------------------------------------------------------------
-- the frame that takes every key (built out of combat; hiding it gives the keys back, also in combat)
function R:Catcher()
    if self.catcher then return self.catcher end
    local f = CreateFrame("Frame", "OneMoreQuestRhythmKeys", UIParent)
    f:SetAllPoints(UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableKeyboard(true)
    if f.SetPropagateKeyboardInput then pcall(f.SetPropagateKeyboardInput, f, false) end
    f:SetScript("OnKeyDown", function(_, key) R:Key(key) end)
    f:Hide()
    self.catcher = f
    return f
end
function R:Grab()
    local f = self:Catcher()
    f:Show()
    self.grabbed = true
end
function R:Release()
    if self.catcher then self.catcher:Hide() end
    self.grabbed = false
end

local function cvar(name) return GetCVar and call(GetCVar, name) end
function R:MuteMusic()
    if not SetCVar then return end
    local was = cvar("Sound_EnableMusic")
    if was == "1" or was == 1 then
        OMQ.db = OMQ.db or {}
        OMQ.db.rhythmMusic = "1"
        call(SetCVar, "Sound_EnableMusic", "0")
    end
end
function R:RestoreMusic()
    if OMQ.db and OMQ.db.rhythmMusic then
        call(SetCVar, "Sound_EnableMusic", OMQ.db.rhythmMusic)
        OMQ.db.rhythmMusic = nil
    end
end

----------------------------------------------------------------------
-- The run: songs -> countdown -> play -> done
----------------------------------------------------------------------
local function changed() OMQ:Fire("RHYTHM_CHANGED") end

function R:Open(source)
    if not self:Unlocked() then note("open.locked"); return nil, "locked" end
    if InCombatLockdown and InCombatLockdown() then note("open.combat"); return nil, "combat" end
    if self.run and self.run.phase ~= "done" then return self.run end
    self.run = { phase = "songs", source = source or "manual", all = self:Ranked(), at = GetTime() }
    self:SetMode(OMQ.db and OMQ.db.rhythmMode or "easy", true)
    note("open." .. (source or "manual"))
    changed()
    return self.run
end

-- the notes of a song, each with a spell: never the same spell three times in a row
function R:Notes(song, count)
    local map = OMQ.Beats and OMQ.Beats[song.id]
    local out = {}
    if not map then return out end
    local last, same = nil, 0
    for i, t in ipairs(map.notes) do
        local s = math.random(count)
        if s == last and same >= 2 then s = s % count + 1 end
        if s == last then same = same + 1 else same = 1 end
        last = s
        out[i] = { t = t, s = s }
    end
    return out
end

-- Easy / Medium / Hard: n spells drawn at random from the 8 most cast spells with a key
function R:SetMode(id, quiet)
    local r = self.run
    if not r or r.phase ~= "songs" then return end
    local m = self:Mode(id)
    r.mode = m
    local pool = {}
    for i = 1, math.min(self.POOL, #r.all) do pool[i] = r.all[i] end
    for i = #pool, 2, -1 do local j = math.random(i); pool[i], pool[j] = pool[j], pool[i] end
    r.spells = {}
    for i = 1, math.min(m.n, #pool) do r.spells[i] = pool[i] end
    if OMQ.db then OMQ.db.rhythmMode = m.id end
    if not quiet then changed() end
end
function R:Ready(mode)
    local r = self.run
    return r and r.all and math.min(#r.all, self.POOL) >= (mode or r.mode).n or false
end

function R:Choose(i)
    local r = self.run
    local song = self.SONGS[i]
    if not (r and song and r.phase == "songs") then return nil end
    if not self:Ready() then note("choose.nospells"); return nil end
    if InCombatLockdown and InCombatLockdown() then self:Stop("combat"); return nil end
    local map = OMQ.Beats and OMQ.Beats[song.id]
    r.song, r.songIndex = song, i
    r.notes = self:Notes(song, #r.spells)
    r.length = map and map.length or 30
    r.phase = "countdown"
    r.goAt = now() + self.COUNTDOWN
    r.perfect, r.good, r.miss, r.combo, r.bestCombo, r.stray, r.next = 0, 0, 0, 0, 0, 0, 1
    local rec = self:Record()
    if rec then rec.plays = rec.plays + 1 end
    self:Grab()
    self:MuteMusic()
    note("choose." .. song.id)
    changed()
    return r
end

function R:Start()
    local r = self.run
    if not r or r.phase ~= "countdown" then return end
    local path = self.MEDIA .. r.song.file
    local will, handle = call(PlaySoundFile, path, "Master")
    if not will then note("sound.off") end
    r.handle, r.soundOff = handle, not will
    local offset = (OMQ.db and num(OMQ.db.rhythmOffset) and OMQ.db.rhythmOffset or 0) / 1000
    r.t0 = now() + offset
    r.phase = "play"
    changed()
end

-- song time (seconds since the song started)
function R:SongTime()
    local r = self.run
    if not r or not r.t0 then return nil end
    return now() - r.t0
end

local function judged(r, n, how, ahead)
    n.done, n.at, n.ahead = how, GetTime(), ahead
    if how == "miss" then
        r.miss = r.miss + 1
        r.combo = 0
    else
        r[how] = r[how] + 1
        r.combo = r.combo + 1
        if r.combo > r.bestCombo then r.bestCombo = r.combo end
    end
    r.last = { how = how, at = GetTime() }
end

-- one key from the keyboard frame
function R:Key(key)
    local r = self.run
    if not r or not str(key) then return end
    if key == "ESCAPE" then self:Stop("esc"); return end
    if key:match("SHIFT$") or key:match("CTRL$") or key:match("ALT$") then return end
    if r.phase ~= "play" then return end
    local full = self.FullKey(key)
    local t = self:SongTime()
    local best, bestD
    for i = r.next, #r.notes do
        local n = r.notes[i]
        local d = t - n.t
        if d < -self.GOOD then break end
        if not n.done and math.abs(d) <= self.GOOD and (not bestD or math.abs(d) < math.abs(bestD)) then best, bestD = n, d end
    end
    if not best then r.stray = r.stray + 1; note("stray"); return end
    local want = r.spells[best.s]
    if want and want.key == full then
        judged(r, best, math.abs(bestD) <= self.PERFECT and "perfect" or "good", -bestD)
    else
        judged(r, best, "miss", -bestD)
        best.wrong, r.last.wrong = true, true
    end
    changed()
end

-- runs every frame while the window is open: countdown end, missed notes, song end
function R:Update()
    local r = self.run
    if not r then return end
    if r.phase == "countdown" and now() >= r.goAt then self:Start(); return end
    if r.phase ~= "play" then return end
    local t = self:SongTime()
    while r.next <= #r.notes do
        local n = r.notes[r.next]
        if n.done then r.next = r.next + 1
        elseif t - n.t > self.GOOD then judged(r, n, "miss"); r.next = r.next + 1
        else break end
    end
    if t >= r.length then self:Finish() end
end

function R:Score(r)
    r = r or self.run
    local total = r and r.notes and #r.notes or 0
    if total == 0 then return 0 end
    return math.floor(100 * (r.perfect + r.good) / total + 0.5)
end

function R:Finish()
    local r = self.run
    if not r or r.phase ~= "play" then return end
    for _, n in ipairs(r.notes) do if not n.done then judged(r, n, "miss") end end
    self:Release()
    self:RestoreMusic()
    local pct = self:Score(r)
    r.pct = pct
    local rec = self:Record()
    if rec then
        local best = rec.best[r.mode.id]
        local old = best[r.song.id]
        r.old = old
        r.record = not old or pct > old
        if r.record then best[r.song.id] = pct end
        rec.done = rec.done + 1
        if pct >= 100 then rec.full = rec.full + 1 end
        if pct >= 80 then rec.high = rec.high + 1 end
        if pct < 30 then rec.low = rec.low + 1 end
        if r.mode.id == "easy" and pct < 30 then rec.lowEasy = (rec.lowEasy or 0) + 1 end
        if r.mode.id == "hard" and pct < 20 then rec.lowHard = (rec.lowHard or 0) + 1 end
        rec.last = time()
    end
    r.phase, r.endAt = "done", GetTime()
    note("done")
    changed()
    if L and L.SafeCheck then L:SafeCheck() end
end

-- ends a run at once: keys back, song off, game music back
function R:Stop(why)
    local r = self.run
    if not r then return end
    self:Release()
    if r.handle and StopSound then call(StopSound, r.handle) end
    self:RestoreMusic()
    if why == "combat" and r.phase ~= "done" then OMQ:Print("Spell Rhythm stopped: you are in combat.") end
    note("stop." .. (why or "close"))
    self.run = nil
    changed()
end

function R:Again()
    local r = self.run
    if not r or r.phase ~= "done" then return end
    self.run = { phase = "songs", source = r.source, all = r.all, at = GetTime() }
    self:SetMode(r.mode.id)
end

function R:Tick()
    local r = self.run
    if r and r.phase == "done" and GetTime() - (r.endAt or 0) >= self.CLOSE_TIME then
        note("closed.timeout")
        self:Stop("timeout")
    end
end

function R:Diag()
    local rec = self:Record() or { best = {} }
    local best = {}
    for _, m in ipairs(self.MODES) do
        for _, s in ipairs(self.SONGS) do
            local v = rec.best[m.id] and rec.best[m.id][s.id]
            if v then best[#best + 1] = m.id .. "/" .. s.id .. " " .. v .. "%" end
        end
    end
    if #best == 0 then best[1] = "-" end
    OMQ:Print(string.format("rhythm: unlocked %s, played %d, finished %d, 100%% %d, 80%%+ %d, <30%% %d; best %s",
        tostring(self:Unlocked()), rec.plays or 0, rec.done or 0, rec.full or 0, rec.high or 0, rec.low or 0, table.concat(best, ", ")))
    local list = {}
    for _, s in ipairs(self:Ranked()) do list[#list + 1] = s.name .. " [" .. s.key .. "] " .. s.uses end
    print("  spells " .. #list .. ": " .. (#list > 0 and table.concat(list, ", ") or "-"))
    print("  offset " .. ((OMQ.db and OMQ.db.rhythmOffset) or 0) .. " ms")
    local keys = {}
    for k, v in pairs(self.diag) do keys[#keys + 1] = k .. "=" .. v end
    table.sort(keys)
    print("  diag " .. (#keys > 0 and table.concat(keys, " ") or "-"))
end

-- test command (not in /omq help): open, offset in ms for the sound delay, diagnostics
OMQ:RegisterCommand("rhythm", function(arg)
    arg = (arg or ""):lower()
    local ms = arg:match("^offset%s+(%-?%d+)$")
    if arg == "open" then
        local _, why = R:Open("manual")
        if why then OMQ:Print("rhythm: " .. why) end
    elseif ms then
        OMQ.db = OMQ.db or {}
        OMQ.db.rhythmOffset = tonumber(ms)
        OMQ:Print("rhythm: offset " .. ms .. " ms")
    else R:Diag() end
end, nil, true)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        if R.run then R:Stop("combat") end
    else
        R:RestoreMusic()   -- a song cut off by a crash or /reload must not leave the game music off
    end
end)

OMQ:On("READY", function()
    C_Timer.NewTicker(1, function()
        local fine, err = pcall(R.Tick, R)
        if not fine then note("err.tick"); OMQ:Error("rhythm tick", err) end
    end)
end)

----------------------------------------------------------------------
-- The Spell Rhythm tab and its entries in the ledger
----------------------------------------------------------------------
if L then
    local pos = #L.TABS + 1
    for i, t in ipairs(L.TABS) do if t.id == "summary" then pos = i end end
    table.insert(L.TABS, pos, { id = "rhythm", name = "Spell Rhythm" })
    local function add(c)
        c.icon = I .. c.icon
        c.need = c.need or 1
        L.CARDS[#L.CARDS + 1] = c
        L.byId[c.id] = c
    end
    local function rec(b) return b.rhythm or {} end
    add({ tab = "rhythm", id = "rhythmopen", title = "Dad Beats", text = "Reach level 30: Spell Rhythm is open", icon = "Ability_Warrior_BattleShout", q = 2,
          value = function(_, ctx) return ctx and num(ctx.level) and ctx.level >= R.MIN_LEVEL and 1 or 0 end })
    -- the best % of one mode: any song reaches pct, or (all) every song reaches it
    local function best(b, mode, pct, all)
        local t = rec(b).best and rec(b).best[mode] or {}
        local hit, n = 0, 0
        for _, song in ipairs(R.SONGS) do
            n = n + 1
            if num(t[song.id]) and t[song.id] >= pct then hit = hit + 1 end
        end
        if all then return n > 0 and hit == n and 1 or 0 end
        return hit > 0 and 1 or 0
    end
    add({ tab = "rhythm", id = "rhythmeasy", title = "Easy Listening", text = "Hit 80% or more of one song on Easy", icon = "INV_Misc_Note_02", q = 2,
          value = function(b) return best(b, "easy", 80) end })
    add({ tab = "rhythm", id = "rhythm80", title = "On Beat", text = "Hit 80% or more of one song on Medium", icon = "Spell_Holy_InnerFire", q = 3,
          value = function(b) return best(b, "medium", 80) end })
    add({ tab = "rhythm", id = "rhythmhard", title = "Shredder", text = "Hit 80% or more of one song on Hard", icon = "Spell_Fire_Fireball02", q = 4,
          value = function(b) return best(b, "hard", 80) end })
    add({ tab = "rhythm", id = "rhythmskip", title = "No Skips", text = "Hit every note of one song on Medium", icon = "Spell_Holy_SealOfMight", q = 3,
          value = function(b) return best(b, "medium", 100) end })
    add({ tab = "rhythm", id = "rhythmalbum", title = "Full Album", text = "Hit 80% or more of all four songs on Medium or on Hard", icon = "INV_Misc_Book_09", q = 4,
          value = function(b) return math.max(best(b, "medium", 80, true), best(b, "hard", 80, true)) end })
    add({ tab = "rhythm", id = "rhythm100", title = "Dad Hero", text = "Hit every note of one song on Hard", icon = "Spell_Nature_Bloodlust", q = 5,
          value = function(b) return best(b, "hard", 100) end })
    add({ tab = "mishaps", id = "rhythm0", title = "Two Left Hands", text = "Hit less than 30% of one song on Easy", icon = "Spell_Shadow_Possession", q = 2,
          value = function(b) return rec(b).lowEasy or 0 end })
    add({ tab = "mishaps", id = "rhythmover", title = "Overconfident", text = "Hit less than 20% of one song on Hard", icon = "Spell_Shadow_DeathScream", q = 2,
          value = function(b) return rec(b).lowHard or 0 end })
end
