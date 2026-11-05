-- One More Quest: Shift-click heals in WoW Forever's click casting (decision 226)
-- Healing classes get two bindings on unit frames (party frames, player, target):
--   Shift + left click  = the emergency heal
--   Shift + right click = the comfortable heal
-- A binding casts exactly the spell id it holds: it does NOT move to a new rank by itself (a Classic
-- rank is its own spell id). So the addon binds the highest learned rank and sets the binding again
-- on every rank up. It picks the best spell the character knows and moves the binding along when a
-- better spell or a higher rank is learned.
-- Rules: existing bindings are never overwritten, only the addon's own. One exception (decision 393):
-- a spell binding of the dad on the highest rank moves along to a newly learned rank. A binding of ours
-- the dad removed or changed by hand stays his; we do not put it back. Only out of combat
-- (SetProfileByInfo is restricted), never while the game's click casting window is open.
-- Modifiers: the game stores Shift as 3 (left and right shift, seen with /omq clicks).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local CH = {}
OMQ.ClickHeals = CH

CH.SHIFT = 3
local SPELL = 1        -- Enum.ClickBindingType.Spell

-- per class: the candidates in order of preference, the last known one wins (base spell ids)
CH.HEALS = {
    PRIEST  = { LeftButton  = { 2050, 2061 },          -- Lesser Heal, from 20 Flash Heal
                RightButton = { 2050, 2054, 2060, 139 } }, -- Lesser Heal, from 8 Renew (decision 405; Heal and
                                                       -- Greater Heal only when Renew cannot be bound)
    PALADIN = { LeftButton  = { 635 },                 -- Holy Light
                RightButton = { 635, 19750 } },        -- Holy Light, from 20 Flash of Light
    DRUID   = { LeftButton  = { 5185, 8936 },          -- Healing Touch, from 12 Regrowth
                RightButton = { 5185, 774 } },         -- Healing Touch, from 4 Rejuvenation
    SHAMAN  = { LeftButton  = { 331, 8004 },           -- Healing Wave, from 20 Lesser Healing Wave
                RightButton = { 331 } },               -- Healing Wave
}
CH.BUTTONS = { "LeftButton", "RightButton" }
local WHAT = { LeftButton = "Shift + left click (emergency)", RightButton = "Shift + right click" }

local function enabled() return OMQ.db and OMQ.db.options and OMQ.db.options.clickHeals ~= false end

local function knows(id)
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    if IsSpellKnown and IsSpellKnown(id) then return true end
    return false
end
local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

-- what the addon set for this character: { LeftButton = id, RightButton = id, given = { LeftButton = true } }
-- given: the dad took the slot over (removed or changed our binding); we leave it alone for good
local function store()
    local me = OMQ.GetSelf and OMQ:GetSelf()
    local guid = (me and me.guid) or (UnitGUID and UnitGUID("player"))
    if not (guid and OMQDB) then return nil end
    OMQDB.clickHeals = OMQDB.clickHeals or {}
    OMQDB.clickHeals[guid] = OMQDB.clickHeals[guid] or { given = {} }
    local st = OMQDB.clickHeals[guid]
    st.given = st.given or {}
    return st
end
CH._store = store

-- the spell for a button, nil when the class has none or nothing is learned yet
function CH.Wanted(button)
    local _, class = UnitClass("player")
    local list = CH.HEALS[class] and CH.HEALS[class][button]
    if not list then return nil end
    local best
    for _, id in ipairs(list) do
        if knows(id) then
            local CB = C_ClickBindings
            if not (CB and CB.CanSpellBeClickBound) or CB.CanSpellBeClickBound(id) then best = id end
        end
    end
    return best and CH.TopRank(best)
end

-- the highest learned rank of every ranked spell in the spell book: { [name] = { id =, rank = } },
-- nil when the book cannot be read
function CH.Tops()
    local SB = C_SpellBook
    if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo) then
        return nil
    end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    local tops = {}
    for line = 1, SB.GetNumSpellBookSkillLines() or 0 do
        local info = SB.GetSpellBookSkillLineInfo(line)
        if info then
            for i = 1, info.numSpellBookItems or 0 do
                local item = SB.GetSpellBookItemInfo((info.itemIndexOffset or 0) + i, bank)
                if item and item.spellID and (spellType == nil or item.itemType == spellType) and not item.isPassive
                    and not item.isOffSpec and knows(item.spellID) then
                    local name = item.name or spellName(item.spellID)
                    local sub = item.subName
                    if (sub == nil or sub == "") and C_Spell and C_Spell.GetSpellSubtext then
                        sub = C_Spell.GetSpellSubtext(item.spellID)
                    end
                    local rank = type(sub) == "string" and tonumber(sub:match("%d+"))
                    if name and rank and (not tops[name] or rank > tops[name].rank) then
                        tops[name] = { id = item.spellID, rank = rank }
                    end
                end
            end
        end
    end
    return tops
end

-- the highest learned rank of a spell; the id itself when the book cannot be read or the spell has no ranks
function CH.TopRank(id, tops)
    tops = tops or CH.Tops()
    local name = spellName(id)
    local t = tops and name and tops[name]
    return t and t.id or id
end

-- decision 393: the dad's own spell bindings follow a new rank too, but only when they held the
-- highest rank before it (a binding on a lower rank was chosen on purpose, downranking: it stays).
-- old: { [name] = id } the highest ranks at the last check (saved per character); now: CH.Tops().
-- Changes profile in place (pure, for the tests), returns how many bindings moved.
-- Without old (first run) nothing moves: we cannot know what the highest rank was.
function CH.Follow(profile, old, now)
    if not (old and now) then return 0 end
    local moved = 0
    for _, info in ipairs(profile) do
        if info.type == SPELL and info.actionID then
            local name = spellName(info.actionID)
            local t = name and now[name]
            if t and old[name] == info.actionID and t.id ~= info.actionID then
                info.actionID = t.id; moved = moved + 1
            end
        end
    end
    return moved
end

local function topIds(now)
    local o = {}
    for name, t in pairs(now) do o[name] = t.id end
    return o
end

local function isShift(m) return m == 1 or m == 2 or m == 3 end

-- the new profile, or nil when nothing changes (pure, for the tests)
-- profile: the game's list; st: our store; wantOf(button) -> spell id or nil; on: the option
function CH.Plan(profile, st, wantOf, on)
    local out, changed, notes = {}, false, {}
    local slot = {}                                    -- button -> index in out of the shift binding
    for _, info in ipairs(profile) do
        out[#out + 1] = { type = info.type, actionID = info.actionID, button = info.button, modifiers = info.modifiers }
        if isShift(info.modifiers) and info.button and slot[info.button] == nil then slot[info.button] = #out end
    end
    local remove = {}
    for _, button in ipairs(CH.BUTTONS) do
        local mine = st[button]
        local idx = slot[button]
        local cur = idx and out[idx]
        local want = on and wantOf(button) or nil
        if mine and not (cur and cur.type == SPELL and cur.actionID == mine) then
            -- our binding is gone or was changed by the dad: the slot is his now
            st[button] = nil
            st.given[button] = true
            mine = nil
        end
        if mine then
            if not want then
                remove[idx] = true; st[button] = nil; changed = true
            elseif want ~= mine then
                notes[#notes + 1] = { button = button, spell = want, from = mine }
                cur.actionID = want; st[button] = want; changed = true
            end
        elseif want and not cur and not st.given[button] then
            out[#out + 1] = { type = SPELL, actionID = want, button = button, modifiers = CH.SHIFT }
            st[button] = want; changed = true
            notes[#notes + 1] = { button = button, spell = want }
        end
    end
    if not changed then return nil, notes end
    local final = {}
    for i, info in ipairs(out) do if not remove[i] then final[#final + 1] = info end end
    return final, notes
end

local pending = false
function CH.Update()
    local CB = C_ClickBindings
    if not (CB and CB.GetProfileInfo and CB.SetProfileByInfo) then return end
    if InCombatLockdown and InCombatLockdown() then pending = true; return end
    if ClickBindingFrame and ClickBindingFrame:IsShown() then pending = true; return end
    pending = false
    local st = store()
    if not st then return end
    local ok, profile = pcall(CB.GetProfileInfo)
    if not ok or type(profile) ~= "table" then return end
    local on = enabled()
    local new, notes = CH.Plan(profile, st, CH.Wanted, on)
    local now = on and CH.Tops() or nil
    if now then
        local base = new
        if not base then
            base = {}
            for i, e in ipairs(profile) do base[i] = { type = e.type, actionID = e.actionID, button = e.button, modifiers = e.modifiers } end
        end
        if CH.Follow(base, st.tops, now) > 0 then new = base end
    end
    if not new then
        if now then st.tops = topIds(now) end
        return
    end
    local okSet, err = pcall(CB.SetProfileByInfo, new)
    if not okSet then
        CH.lastError = tostring(err)
        if not CH.warned then
            CH.warned = true
            OMQ:Print("Click casting: the game did not let the addon set the Shift-click heals (" .. CH.lastError .. ")")
        end
        return
    end
    if now then st.tops = topIds(now) end
    for _, n in ipairs(notes) do
        -- a higher rank of the same spell is set quietly; a new spell gets one line
        if not (n.from and spellName(n.from) == spellName(n.spell)) then
            OMQ:Print(string.format("Click casting: %s on a unit frame casts %s", WHAT[n.button], spellName(n.spell) or "?"))
        end
    end
end

local queued = false
local function soon()
    if queued then return end
    queued = true
    C_Timer.After(1, function() queued = false; local ok, err = pcall(CH.Update); if not ok then OMQ:Error("clickheals", err) end end)
end
CH.Soon = soon

local ev = CreateFrame("Frame")
for _, e in ipairs({ "SPELLS_CHANGED", "PLAYER_LEVEL_UP", "LEARNED_SPELL_IN_TAB", "PLAYER_REGEN_ENABLED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and not pending then return end
    soon()
end)

-- the game's window closed: a change may have waited for it
local watch = CreateFrame("Frame")
local acc = 0
watch:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + (elapsed or 0)
    if acc < 2 then return end
    acc = 0
    if pending and not (ClickBindingFrame and ClickBindingFrame:IsShown()) then soon() end
end)

OMQ:On("READY", function() C_Timer.After(3, soon) end)

-- decision 243: the first time the heals are set, one card explains them (once per character)
CH.TITLE = { LeftButton = "Shift + left click", RightButton = "Shift + right click" }
if OMQ.Alerts then
    OMQ.Alerts:Register({ id = "clickintro", name = "Shift-click heals: the introduction", check = function()
        if not enabled() then return nil end
        local st = store()
        if not st or st.introDone or not (st.LeftButton or st.RightButton) then return nil end
        local parts, tip = {}, { "Shift-click heals", "On a party, player or target frame, hold Shift and click:" }
        for _, b in ipairs(CH.BUTTONS) do
            local n = st[b] and spellName(st[b])
            if n then
                parts[#parts + 1] = (b == "LeftButton" and "left " or "right ") .. n
                tip[#tip + 1] = { CH.TITLE[b], n .. (b == "LeftButton" and " (emergency)" or "") }
            end
        end
        tip[#tip + 1] = "The addon moves them to better heals as you learn them. Your own bindings only move up to a new rank."
        tip[#tip + 1] = "Click this card to close it."
        return { {
            key = "clickintro", title = "New: Shift-click heals", tag = "HEALER",
            sub = "Shift + click a party frame - hover for details",   -- always fits (decision 245)
            text = "New: Shift-click heals", tipLines = tip,
            icon = "Interface\\Icons\\Spell_Holy_FlashHeal", color = { 0.49, 0.78, 0.44 },
        } }
    end })
    OMQ:On("ALERT_DISMISSED", function(key)
        if key == "clickintro" then
            local st = store()
            if st then st.introDone = true end
        end
    end)
end
