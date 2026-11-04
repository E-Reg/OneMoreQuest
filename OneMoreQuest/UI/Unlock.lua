-- One More Quest: new features step by step
-- Some features open by level, others the first time something happens in the game. When one opens, a card
-- with a light flash and a fanfare shows what is new, waits a few seconds (longer while the mouse is on it) and
-- flies into the minimap icon; a right click sends it off.
-- Cards never overlap: they wait in a queue, never during a fight, and start 5 s after a level up.
-- Per character: OMQDB.unlock[guid] = { got = { id = time }, shown = { id = time } }.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local U = {}
OMQ.Unlock = U

U.AFTER_LEVEL = 5          -- seconds after a level up (the game's own fanfare first)
U.AFTER_LOGIN = 5
U.GAP = 0.5                -- between two cards
-- the card's time line in seconds
U.T_IN, U.T_ICON, U.T_TEXT, U.T_BAR, U.T_FLY, U.T_END = 0.1, 0.25, 0.6, 1.4, 9.0, 10.5
U.FLY_TIME = 0.7

local I = "Interface\\Icons\\"
-- level = opens at this level; otherwise check() tells whether the event has happened (also afterwards)
U.LIST = {
    { id = "bets", level = 5, title = "Bets", icon = I .. "INV_Misc_Coin_02", where = "Check bar",
      desc = "Bet gold against the other dads. Decided automatically, debts paid by mail." },
    { id = "journey", level = 10, title = "Forever Journey", icon = I .. "INV_Misc_Book_09", where = "Minimap quick options",
      desc = "Every step of your character becomes a card. Collect them and flex them to the dads." },
    { id = "dungeon", level = 13, title = "Dungeon Check", icon = I .. "INV_Misc_Key_03", where = "Check bar",
      desc = "A check for every dungeon of your level: quests, best boss loot and the way to the entrance." },
    { id = "duel", level = 15, title = "Dad Duel", icon = I .. "Ability_Warrior_Challange", where = "Check bar",
      desc = "Challenge the dads with the foes you have slain. Five rounds, one winner." },
    { id = "rhythm", level = 20, title = "Spell Rhythm", icon = I .. "INV_Misc_Drum_01", where = "Flight invite or check bar",
      desc = "Play your own spells to the beat. Four songs, three difficulties." },
    { id = "quiz", event = "First flight master", title = "Flight Quiz", icon = I .. "INV_Misc_QuestionMark", where = "Before every flight",
      desc = "Five questions about your own journey on every flight. How well do you know yourself?" },
    { id = "auction", event = "First capital city", title = "Auction Helper", icon = I .. "INV_Misc_Bag_10", where = "At the auctioneer",
      desc = "Post everything worth more with one click, and stock up on what your class needs." },
    { id = "profession", event = "First profession learned", title = "Profession Helper", icon = I .. "Trade_BlackSmithing", where = "Your profession window",
      desc = "Crafting profit, the cheapest skill-up and who in the group needs your materials." },
    { id = "threat", event = "First dungeon entered", title = "Threat Meter", icon = I .. "Spell_Nature_Reincarnation", where = "Shows in dungeons",
      desc = "Everybody's threat on your target. As the tank you see who pulls the aggro off you." },
}
U.byId = {}
for _, d in ipairs(U.LIST) do U.byId[d.id] = d end

-- crafting professions (with Cooking and First Aid), by the keys of Guide.ProfKey
U.CRAFT = { Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Leatherworking = true,
            Tailoring = true, Cooking = true, ["First Aid"] = true }
-- capital cities: Classic map ids (WoW Forever) and the retail ones, plus Booty Bay by its sub zone name
U.CITY_MAPS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true,
                [84] = true, [85] = true, [87] = true, [88] = true, [89] = true, [90] = true }
U.CITY_ZONES = { ["Booty Bay"] = true, ["Beutebucht"] = true }

-- the fanfare: the battleground victory of the own faction; the level up sound when the game has neither
U.SOUNDS = {
    Alliance = { { kit = "PVP_VICTORY_ALLIANCE", id = 8455 } },
    Horde = { { kit = "PVP_VICTORY_HORDE", id = 8454 } },
    fallback = { kit = "LEVELUPSOUND", id = 888 },
}

local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function str(v) return type(v) == "string" and ok(v) and v ~= "" end
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2)
end
local function now() return GetTime and GetTime() or 0 end

U.diag = {}
local function note(k) U.diag[k] = (U.diag[k] or 0) + 1 end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
function U:Record()
    if not OMQDB then return nil end
    local me = OMQ:GetSelf()
    if not me then return nil end
    OMQDB.unlock = OMQDB.unlock or {}
    local r = OMQDB.unlock[me.guid]
    if not r then r = { got = {}, shown = {} }; OMQDB.unlock[me.guid] = r end
    r.got, r.shown = r.got or {}, r.shown or {}
    return r
end

local function level()
    local l = UnitLevel and call(UnitLevel, "player")
    return num(l) and l or 1
end

-- is the feature open for me?
function U:Has(id)
    local d = self.byId[id]
    if not d then return true end
    if d.level then return level() >= d.level end
    local r = self:Record()
    return r ~= nil and r.got[id] ~= nil
end

function U:Level(id) local d = self.byId[id]; return d and d.level end

-- the level of another dad in my group, or nil when the game does not tell
function U.LevelOf(guid)
    if not guid then return nil end
    local units = { "player" }
    if IsInRaid and call(IsInRaid) then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    else
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    for _, u in ipairs(units) do
        if UnitGUID and call(UnitGUID, u) == guid then
            local l = UnitLevel and call(UnitLevel, u)
            return num(l) and l > 0 and l or nil
        end
    end
    return nil
end

-- may this dad take part in a feature that opens by level? (unknown level: yes)
function U:Allows(id, guid)
    local need = self:Level(id)
    if not need then return true end
    local l = U.LevelOf(guid)
    return l == nil or l >= need
end

----------------------------------------------------------------------
-- What has happened (live, and from the counters of the book for older characters)
----------------------------------------------------------------------
local function book() return OMQ.Tally and OMQ.Tally.Book and call(OMQ.Tally.Book) end

local function talkedTo(b, kind)
    for _, n in pairs(b and b.npcs or {}) do if n.k and n.k[kind] then return true end end
    return false
end

function U.InCity()
    local map = C_Map and C_Map.GetBestMapForUnit and call(C_Map.GetBestMapForUnit, "player")
    if num(map) and U.CITY_MAPS[map] then return true end
    for _, fn in ipairs({ GetSubZoneText, GetMinimapZoneText, GetZoneText }) do
        local z = call(fn)
        if str(z) and U.CITY_ZONES[z] then return true end
    end
    return false
end

function U.InDungeon()
    if not IsInInstance then return false end
    local inside, kind = call(IsInInstance)
    return inside and (kind == "party" or kind == "raid") or false
end

function U.HasCraft()
    local lines = OMQ.Alerts and OMQ.Alerts.ProfessionLines and call(OMQ.Alerts.ProfessionLines)
    for _, l in ipairs(lines or {}) do if l.key and U.CRAFT[l.key] then return true end end
    return false
end

local CHECKS = {
    quiz = function(b) return talkedTo(b, "flight") or (b and b.move and (b.move.flights or 0) > 0) or false end,
    auction = function(b)
        if U.InCity() or talkedTo(b, "auction") then return true end
        for id in pairs(b and b.maps or {}) do if U.CITY_MAPS[id] then return true end end
        return false
    end,
    profession = function() return U.HasCraft() end,
    threat = function(b) return U.InDungeon() or (b and b.dungeons and #b.dungeons > 0) or false end,
}
U.CHECKS = CHECKS

-- marks an event feature as open (from the game events)
function U:Grant(id)
    local r = self:Record()
    if not r or not self.byId[id] or r.got[id] then return false end
    r.got[id] = time()
    note("grant." .. id)
    self:Check()
    return true
end

local queue = {}
U.queue = queue
local function queued(id) for _, q in ipairs(queue) do if q == id then return true end end; return false end

-- looks for what has opened and puts its card in the queue
function U:Check()
    local r = self:Record()
    if not r then return nil end
    local b = book()
    local fresh = {}
    for _, d in ipairs(self.LIST) do
        local open
        if d.level then
            open = level() >= d.level
            if open and d.id == "journey" then open = OMQ.Ledger and call(OMQ.Ledger.Open, OMQ.Ledger) or false end
            if open and not r.got[d.id] then r.got[d.id] = time() end
        else
            open = r.got[d.id] ~= nil
            if not open and CHECKS[d.id] and CHECKS[d.id](b) then r.got[d.id] = time(); open = true end
        end
        if open and not r.shown[d.id] and not queued(d.id) and not (self.cur and self.cur.def.id == d.id) then
            queue[#queue + 1] = d.id
            fresh[#fresh + 1] = d.id
        end
    end
    if #fresh > 0 then
        note("new")
        OMQ:Fire("UNLOCK", fresh)
    end
    return fresh
end

----------------------------------------------------------------------
-- The card
----------------------------------------------------------------------
local GOLD = { 0.89, 0.71, 0.29 }
local card, flash
U.holdUntil = 0

local function tex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer)
    if r then t:SetColorTexture(r, g, b, a or 1) end
    return t
end

local function build()
    flash = CreateFrame("Frame", "OneMoreQuestUnlockFlash", UIParent)
    flash:SetAllPoints(UIParent)
    flash:SetFrameStrata("FULLSCREEN_DIALOG")
    flash.glow = flash:CreateTexture(nil, "BACKGROUND")
    flash.glow:SetTexture("Interface\\Cooldown\\star4")
    if flash.glow.SetBlendMode then flash.glow:SetBlendMode("ADD") end
    flash.glow:SetVertexColor(1, 0.85, 0.45)
    flash.glow:SetSize(900, 900)
    flash.glow:SetPoint("CENTER", UIParent, "TOP", 0, -260)
    flash:Hide()

    card = CreateFrame("Button", "OneMoreQuestUnlock", UIParent)
    card:SetSize(460, 200)
    card:SetFrameStrata("FULLSCREEN_DIALOG")
    card:SetClampedToScreen(false)
    card.bg = tex(card, "BACKGROUND", 0.07, 0.08, 0.105, 0.97)
    card.bg:SetAllPoints()
    card.edges = {}
    for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
                         { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil } }) do
        local t = tex(card, "BORDER", GOLD[1], GOLD[2], GOLD[3], 0.8)
        t:SetPoint(p[1]); t:SetPoint(p[2])
        if p[3] then t:SetWidth(p[3]) else t:SetHeight(p[4]) end
        card.edges[i] = t
    end
    -- rays behind the icon: two stars turning against each other
    card.rays = {}
    for i = 1, 2 do
        local r = card:CreateTexture(nil, "BACKGROUND", nil, -1)
        r:SetTexture("Interface\\Cooldown\\star4")
        if r.SetBlendMode then r:SetBlendMode("ADD") end
        r:SetVertexColor(1, 0.82, 0.4, 0.8)
        r:SetSize(260, 260)
        r:SetPoint("CENTER", card, "TOP", 0, 8)
        card.rays[i] = r
    end
    card.ring = card:CreateTexture(nil, "ARTWORK")
    card.ring:SetSize(84, 84)
    card.ring:SetPoint("CENTER", card, "TOP", 0, 8)
    card.ring:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    card.icon = card:CreateTexture(nil, "OVERLAY")
    card.icon:SetSize(76, 76)
    card.icon:SetPoint("CENTER", card.ring, "CENTER")
    card.head = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.head:SetPoint("TOP", 0, -58)
    card.head:SetText("NEW FEATURE UNLOCKED")
    card.head:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    card.title:SetPoint("TOP", card.head, "BOTTOM", 0, -6)
    if card.title.SetFont then pcall(card.title.SetFont, card.title, "Fonts\\MORPHEUS.TTF", 28, "") end
    card.title:SetTextColor(0.96, 0.9, 0.76)
    card.desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.desc:SetPoint("TOP", card.title, "BOTTOM", 0, -8)
    card.desc:SetWidth(400)
    card.line = tex(card, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 0.35)
    card.line:SetHeight(1)
    card.line:SetPoint("BOTTOMLEFT", 20, 34); card.line:SetPoint("BOTTOMRIGHT", -20, 34)
    card.trigger = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.trigger:SetPoint("BOTTOMLEFT", 20, 16)
    card.trigger:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    card.where = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.where:SetPoint("BOTTOMRIGHT", -20, 16)
    card.bar = tex(card, "OVERLAY", GOLD[1], GOLD[2], GOLD[3], 1)
    card.bar:SetHeight(3)
    card.bar:SetPoint("BOTTOMLEFT", 0, 0)
    card.texts = { card.head, card.title, card.desc, card.line, card.trigger, card.where }
    -- a right click sends the card off; while the mouse is on it, the time stands still
    if card.RegisterForClicks then card:RegisterForClicks("RightButtonUp") end
    card:SetScript("OnClick", function(_, button) if button == "RightButton" then U:Skip() end end)
    card:SetScript("OnEnter", function() U.hover = true end)
    card:SetScript("OnLeave", function() U.hover = false end)
    card:SetScript("OnUpdate", function() U:Tick() end)
    card:Hide()
end

local function minimapCenter()
    local b = _G.OneMoreQuestMinimapButton
    if not (b and b.IsShown and call(b.IsShown, b)) then return nil end
    local x, y = call(b.GetCenter, b)
    local ux, uy = call(UIParent.GetCenter, UIParent)
    if not (num(x) and num(y) and num(ux) and num(uy)) then return nil end
    local s = (call(b.GetEffectiveScale, b) or 1) / (call(UIParent.GetEffectiveScale, UIParent) or 1)
    return x * s - ux, y * s - uy
end

local function fanfare()
    local fac = UnitFactionGroup and call(UnitFactionGroup, "player")
    local list = U.SOUNDS[fac] or U.SOUNDS.Alliance
    if not PlaySound then return nil end
    for _, s in ipairs(list) do
        local id = (_G.SOUNDKIT and _G.SOUNDKIT[s.kit]) or s.id
        local fine, will = pcall(PlaySound, id, "Master")
        if fine and will ~= false then note("sound"); return id end
    end
    local f = U.SOUNDS.fallback
    local id = (_G.SOUNDKIT and _G.SOUNDKIT[f.kit]) or f.id
    pcall(PlaySound, id, "Master")
    note("sound.fallback")
    return id
end
U.Fanfare = fanfare

local function triggerText(d)
    if d.level then return "Level " .. d.level .. " reached" end
    return d.event
end

function U:Busy() return self.cur ~= nil end

-- starts the next card when nothing stands in the way
function U:Next()
    if self.cur or #queue == 0 then return false end
    if now() < (self.holdUntil or 0) then return false end
    if (InCombatLockdown and call(InCombatLockdown)) or (UnitAffectingCombat and call(UnitAffectingCombat, "player")) then
        note("wait.combat")
        return false
    end
    local id = table.remove(queue, 1)
    local d = self.byId[id]
    if not d then return false end
    if not card then build() end
    self.cur = { def = d, at = now() }
    card.icon:SetTexture(d.icon)
    card.title:SetText(d.title)
    card.desc:SetText(d.desc)
    card.trigger:SetText(triggerText(d))
    card.where:SetText("Find it: " .. d.where)
    self.cur.sound = fanfare()
    flash:Show()
    card:Show()
    self:Tick()
    note("show." .. id)
    return true
end

local function clamp(v) return math.max(0, math.min(1, v)) end
local function ease(v) v = clamp(v); return 1 - (1 - v) * (1 - v) end

-- one frame of the animation (also driven by the tests)
function U:Tick()
    local c = self.cur
    if not (c and card) then return end
    local tnow = now()
    -- the mouse on the card: the reading time stands still, only once the card is complete and its bar runs
    -- (the intro is never held up), until it flies off
    if U.hover and c.last and (tnow - c.at) >= U.T_BAR and (tnow - c.at) < (c.flyAt or U.T_FLY) then
        c.at = c.at + (tnow - c.last)
        if not c.paused then c.paused = true; note("pause") end
    end
    c.last = tnow
    local t = tnow - c.at
    -- flash
    local fa = t < 0.12 and t / 0.12 or clamp(1 - (t - 0.12) / 0.9)
    flash.glow:SetAlpha(fa * 0.9)
    if t > 0.12 and fa <= 0 then flash:Hide() end
    -- card position: slides in from above, later flies into the minimap icon
    local x, y, scale, alpha = 0, -150, 1, 1
    local tin = clamp((t - U.T_IN) / 0.35)
    alpha = ease(tin)
    y = -150 + (1 - ease(tin)) * 16
    local fly = c.flyAt or U.T_FLY
    if t >= fly then
        local f = clamp((t - fly) / U.FLY_TIME)
        scale = 1 - 0.94 * f
        if c.target == nil then
            local mx, my = minimapCenter()
            c.target = mx and { mx, my } or false
        end
        if c.target then
            -- the card hangs at its top edge; its middle has to end on the icon
            local half = (UIParent.GetHeight and call(UIParent.GetHeight, UIParent) or 768) / 2
            local yEnd = c.target[2] - half + 100 * scale
            x = c.target[1] * f * f
            y = -150 + (yEnd + 150) * f * f
        end
        alpha = 1 - f
        if f >= 1 and not c.landed then
            c.landed = true
            note("landed")
        end
    end
    card:ClearAllPoints()
    card:SetPoint("TOP", UIParent, "TOP", x / scale, y / scale)
    card:SetScale(math.max(0.06, scale))
    card:SetAlpha(alpha)
    -- rays turn, the icon pops up with a small overshoot
    for i, r in ipairs(card.rays) do
        r:SetAlpha(clamp((t - 0.2) / 0.5) * 0.8)
        if r.SetRotation then r:SetRotation((i == 1 and 1 or -0.6) * t * 0.26 + (i - 1) * 0.4) end
    end
    local p = clamp((t - U.T_ICON) / 0.55)
    local s = p < 0.6 and (p / 0.6) * 1.25 or 1.25 - (p - 0.6) / 0.4 * 0.25
    card.icon:SetSize(math.max(1, 76 * s), math.max(1, 76 * s))
    card.ring:SetSize(math.max(1, 84 * s), math.max(1, 84 * s))
    for i, w in ipairs(card.texts) do w:SetAlpha(clamp((t - U.T_TEXT - (i - 1) * 0.15) / 0.4)) end
    local barLeft = clamp(1 - (t - U.T_BAR) / (fly - U.T_BAR))
    card.bar:SetWidth(math.max(0.01, 460 * barLeft))
    if t >= fly + U.FLY_TIME + 0.8 then self:Done() end
end

-- a click on the card: it flies off at once
function U:Skip()
    local c = self.cur
    if not c then return end
    local t = now() - c.at
    if t < (c.flyAt or U.T_FLY) then c.flyAt = math.max(t, U.T_TEXT); note("skip") end
end

function U:Done()
    local c = self.cur
    if not c then return end
    local r = self:Record()
    if r then r.shown[c.def.id] = time() end
    self.cur = nil
    self.hover = false
    if card then card:Hide() end
    if flash then flash:Hide() end
    self.holdUntil = math.max(self.holdUntil or 0, now() + U.GAP)
    OMQ:Fire("UNLOCK_SHOWN", c.def.id)
end

function U:Frame() return card end

-- test and diagnostics: play a card again, or all of them one after the other
function U:Demo(id)
    if id == "all" then
        for _, d in ipairs(self.LIST) do if not queued(d.id) then queue[#queue + 1] = d.id end end
    elseif self.byId[id] then
        if not queued(id) then queue[#queue + 1] = id end
    else
        return false
    end
    self.holdUntil = 0
    return true
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
                     "ZONE_CHANGED_INDOORS", "TAXIMAP_OPENED", "SKILL_LINES_CHANGED", "TRADE_SKILL_SHOW",
                     "CHAT_MSG_SKILL", "LEARNED_SPELL_IN_TAB" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local HANDLERS = {
    PLAYER_LEVEL_UP = function()
        U.holdUntil = math.max(U.holdUntil or 0, now() + U.AFTER_LEVEL)
        if C_Timer and C_Timer.After then C_Timer.After(0.5, function() U:Check() end) end
    end,
    PLAYER_ENTERING_WORLD = function() U:Check() end,
    TAXIMAP_OPENED = function() U:Grant("quiz") end,
    ZONE_CHANGED_NEW_AREA = function()
        if U.InCity() then U:Grant("auction") end
        if U.InDungeon() then U:Grant("threat") end
    end,
    SKILL_LINES_CHANGED = function() if U.HasCraft() then U:Grant("profession") end end,
}
HANDLERS.ZONE_CHANGED = HANDLERS.ZONE_CHANGED_NEW_AREA
HANDLERS.ZONE_CHANGED_INDOORS = HANDLERS.ZONE_CHANGED_NEW_AREA
HANDLERS.TRADE_SKILL_SHOW = HANDLERS.SKILL_LINES_CHANGED
HANDLERS.CHAT_MSG_SKILL = HANDLERS.SKILL_LINES_CHANGED
HANDLERS.LEARNED_SPELL_IN_TAB = HANDLERS.SKILL_LINES_CHANGED
ev:SetScript("OnEvent", function(_, e, ...)
    local fine, err = pcall(HANDLERS[e], ...)
    if not fine then OMQ:Error("unlock " .. tostring(e), err) end
end)

OMQ:On("LEDGER_NEW", function() U:Check() end)

OMQ:On("READY", function()
    U.holdUntil = math.max(U.holdUntil or 0, now() + U.AFTER_LOGIN)
    U:Check()
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(1, function()
            local fine, err = pcall(function()
                if not U.cur then
                    U.tick = (U.tick or 0) + 1
                    if U.tick % 10 == 0 then U:Check() end
                    U:Next()
                end
            end)
            if not fine then OMQ:Error("unlock", err) end
        end)
    end
end)

-- hidden test command: /omq unlock [status | demo <id> | demo all | sound | reset <id>]
OMQ:RegisterCommand("unlock", function(arg)
    local cmd, rest = (arg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "demo" then
        if not U:Demo(rest ~= "" and rest or "all") then
            local ids = {}
            for _, d in ipairs(U.LIST) do ids[#ids + 1] = d.id end
            OMQ:Print("unlock demo: all | " .. table.concat(ids, " | "))
        end
        U:Next()
        return
    end
    if cmd == "sound" then
        OMQ:Print("unlock sound: " .. tostring(fanfare()))
        return
    end
    if cmd == "reset" and U.byId[rest] then
        local r = U:Record()
        if r then r.got[rest], r.shown[rest] = nil, nil end
        OMQ:Print("unlock: " .. rest .. " reset")
        return
    end
    local r = U:Record() or { got = {}, shown = {} }
    for _, d in ipairs(U.LIST) do
        print(string.format("  %s: %s, %s", d.id, U:Has(d.id) and "open" or "closed",
            r.shown[d.id] and "shown" or (queued(d.id) and "waiting" or "-")))
    end
    local keys = {}
    for k, v in pairs(U.diag) do keys[#keys + 1] = k .. "=" .. v end
    table.sort(keys)
    OMQ:Print("unlock: queue " .. #queue .. ", " .. table.concat(keys, " "))
end, nil, true)
