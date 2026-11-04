-- One More Quest: guidance (destinations for the arrow)
-- A destination beats the straggler mode of the arrow until the player arrives
-- or cancels it. Sources: fixed places (Data\Places.lua, map percent coordinates
-- converted to world coordinates at runtime), learned places (Guide\Places.lua),
-- the map pin, the corpse and a shared meeting point.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local ARRIVE_YARDS = 12

local G = {}
OMQ.Guide = G

G.kinds = {
    -- id, label, icon, learned-only?
    { id = "trainer", label = "Class trainer",  icon = "Interface\\Icons\\INV_Misc_Book_09" },
    { id = "vendor",  label = "Vendor",         icon = "Interface\\Icons\\INV_Misc_Bag_07" },
    { id = "repair",  label = "Repair",         icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { id = "auction", label = "Auction house",  icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    { id = "bank",    label = "Bank",           icon = "Interface\\Icons\\INV_Misc_Bag_10" },
    { id = "flight",  label = "Flight master",  icon = "Interface\\Icons\\Ability_Mount_Gryphon_01" },
    { id = "mailbox", label = "Mailbox",        icon = "Interface\\Icons\\INV_Letter_15" },
    { id = "inn",     label = "Inn (hearthstone)", icon = "Interface\\Icons\\INV_Misc_Rune_01" },
    { id = "pin",     label = "Map pin",        icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { id = "corpse",  label = "My corpse",      icon = "Interface\\Icons\\Spell_Holy_GuardianSpirit" },
}
G.profIcons = {
    ["Alchemy"] = "Interface\\Icons\\Trade_Alchemy", ["Blacksmithing"] = "Interface\\Icons\\Trade_BlackSmithing",
    ["Enchanting"] = "Interface\\Icons\\Trade_Engraving", ["Engineering"] = "Interface\\Icons\\Trade_Engineering",
    ["Leatherworking"] = "Interface\\Icons\\Trade_LeatherWorking", ["Tailoring"] = "Interface\\Icons\\Trade_Tailoring",
    ["Herbalism"] = "Interface\\Icons\\Trade_Herbalism", ["Mining"] = "Interface\\Icons\\Trade_Mining",
    ["Skinning"] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01", ["Cooking"] = "Interface\\Icons\\INV_Misc_Food_15",
    ["First Aid"] = "Interface\\Icons\\INV_Misc_Bandage_15", ["Fishing"] = "Interface\\Icons\\Trade_Fishing",
}
-- Professions are identified by their skill line id (language independent) and,
-- as a fallback, by their English or German name.
local PROF_LINE = {
    [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering",
    [182] = "Herbalism", [165] = "Leatherworking", [186] = "Mining", [393] = "Skinning",
    [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid", [356] = "Fishing",
}
local PROF_NAME = {
    alchemy = "Alchemy", alchemie = "Alchemy",
    blacksmithing = "Blacksmithing", schmiedekunst = "Blacksmithing",
    enchanting = "Enchanting", verzauberkunst = "Enchanting",
    engineering = "Engineering", ingenieurskunst = "Engineering",
    herbalism = "Herbalism", ["kräuterkunde"] = "Herbalism",
    leatherworking = "Leatherworking", lederverarbeitung = "Leatherworking",
    mining = "Mining", bergbau = "Mining",
    skinning = "Skinning", ["kürschnerei"] = "Skinning",
    tailoring = "Tailoring", schneiderei = "Tailoring",
    cooking = "Cooking", kochkunst = "Cooking", kochen = "Cooking",
    ["first aid"] = "First Aid", ["erste hilfe"] = "First Aid",
    fishing = "Fishing", angeln = "Fishing",
}
function G.ProfKey(skillLine, name)
    if skillLine and PROF_LINE[skillLine] then return PROF_LINE[skillLine] end
    if type(name) == "string" then return PROF_NAME[name:lower()] end
end

local KIND = {}
for _, k in ipairs(G.kinds) do KIND[k.id] = k end

local dest = nil        -- { kind, label, cands = {{name,a,b,inst}}, idx, manual }

local function isSecret(v) return issecretvalue and issecretvalue(v) end

local function xyOf(v)
    if type(v) ~= "table" then return nil end
    if v.GetXY then local ok, x, y = pcall(v.GetXY, v); if ok then return x, y end end
    return v.x, v.y
end

-- map percent (0-100) -> world coordinates, instance
local function worldFromMap(map, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, inst, vec = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if not ok then return nil end
    local a, b = xyOf(vec)
    if type(a) ~= "number" or type(b) ~= "number" then return nil end
    return a, b, inst
end

local function myPos()
    if not UnitPosition then return nil end
    local a, b, _, inst = UnitPosition("player")
    if type(a) ~= "number" or type(b) ~= "number" or isSecret(a) or isSecret(b) then return nil end
    return { a = a, b = b, inst = inst }
end

local function factionCode()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    if f == "Alliance" then return "A" elseif f == "Horde" then return "H" end
end

----------------------------------------------------------------------
-- Candidate lists per kind
----------------------------------------------------------------------
-- world positions of the fixed places, worked out once (there are more than 1500 of them)
local worldCache = {}
local function worldOf(p)
    local w = worldCache[p]
    if w == nil then
        local a, b, inst = worldFromMap(p[3], p[4] / 100, p[5] / 100)
        w = a and { a, b, inst } or false
        if a or not (C_Map and C_Map.GetWorldPosFromMapPos) then worldCache[p] = w end
    end
    return w or nil
end
G.WorldOf = worldOf

-- name as this client shows it, and the NPC's function ("Druidenlehrer" on a German client)
function G.Title(name)
    local t = OMQ.placeTitles and OMQ.placeTitles[name]
    if not t then return name, nil end
    if GetLocale and GetLocale() == "deDE" then return t[2] or name, t[3] or t[1] end
    return name, t[1]
end

local function fixedCandidates(kind, arg)
    local out = {}
    local fac = factionCode()
    local _, class = UnitClass("player")
    for _, p in ipairs(OMQ.fixedPlaces or {}) do
        local k, cls, map, x, y, f, name = p[1], p[2], p[3], p[4], p[5], p[6], p[7]
        if k == kind and (not cls or cls == (arg or class)) and (not fac or f == "AH" or f == fac)
            and not (p[8] and (UnitLevel and tonumber((UnitLevel("player"))) or 0) > p[8]) then    -- decision 253
            local w = worldOf(p)
            if w then
                local shown, title = G.Title(name)
                out[#out + 1] = { name = shown, title = title, a = w[1], b = w[2], inst = w[3], map = map }
            end
        end
    end
    return out
end

local function learnedCandidates(kind, cls)
    local out = {}
    for _, p in ipairs(OMQ.Places and OMQ.Places:All(kind) or {}) do
        if not cls or p.cls == cls then
            out[#out + 1] = { name = p.name, a = p.a, b = p.b, inst = p.inst, map = p.map }
        end
    end
    return out
end

local function pinCandidates()
    if not (C_Map and C_Map.GetUserWaypoint) then return {} end
    local ok, wp = pcall(C_Map.GetUserWaypoint)
    if not ok or type(wp) ~= "table" or not wp.uiMapID then return {} end
    local x, y = xyOf(wp.position)
    if type(x) ~= "number" then return {} end
    local a, b, inst = worldFromMap(wp.uiMapID, x, y)
    if not a then return {} end
    return { { name = "Map pin", a = a, b = b, inst = inst, map = wp.uiMapID } }
end

local function corpseCandidates()
    if not (C_DeathInfo and C_DeathInfo.GetCorpseMapPosition and C_Map and C_Map.GetBestMapForUnit) then return {} end
    local map = C_Map.GetBestMapForUnit("player")
    if not map then return {} end
    local ok, v = pcall(C_DeathInfo.GetCorpseMapPosition, map)
    if not ok then return {} end
    local x, y = xyOf(v)
    if type(x) ~= "number" or isSecret(x) then return {} end
    local a, b, inst = worldFromMap(map, x, y)
    if not a then return {} end
    return { { name = "My corpse", a = a, b = b, inst = inst, map = map } }
end

function G:Candidates(kind, arg)
    if kind == "pin" then return pinCandidates() end
    if kind == "corpse" then return corpseCandidates() end
    local out = fixedCandidates(kind, arg)
    if kind ~= "proftrainer" and kind ~= "tool" then
        -- what the group learned enriches the fixed list; the same NPC twice counts once (decision 186);
        -- class trainers only those the player knows as his own class trainer (decision 218)
        local fixedN = #out
        local cls = kind == "trainer" and select(2, UnitClass("player")) or nil
        if kind == "trainer" and not cls then return out end
        for _, c in ipairs(learnedCandidates(kind, cls)) do
            local dup = false
            for i = 1, fixedN do
                local f = out[i]
                if f.inst == c.inst and math.abs(f.a - c.a) < 15 and math.abs(f.b - c.b) < 15 then dup = true; break end
            end
            if not dup then out[#out + 1] = c end
        end
    end
    return out
end

local function distance(mine, c)
    if mine and c.inst == mine.inst then
        return math.sqrt((c.a - mine.a) ^ 2 + (c.b - mine.b) ^ 2)
    end
end

-- sorted by distance; places on another continent come last
local function sortByDistance(list, mine)
    for _, c in ipairs(list) do c.d = distance(mine, c) end
    table.sort(list, function(x, y)
        if x.d and y.d then return x.d < y.d end
        if x.d then return true end
        if y.d then return false end
        return (x.name or "") < (y.name or "")
    end)
end

----------------------------------------------------------------------
-- Destination control
----------------------------------------------------------------------
function G:Start(spec)
    if not OMQ:Master("guidance") then return false end
    local kind, arg = tostring(spec):match("^([^:]+):?(.*)$")
    if arg == "" then arg = nil end
    local info = KIND[kind]
    if kind == "proftrainer" and arg then info = { label = arg .. " trainer" } end
    -- a vendor who sells a profession tool (decision 236): "tool:<item ID>"
    if kind == "tool" and arg then
        local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(tonumber(arg))
        info = { label = ((type(n) == "string" and not isSecret(n)) and n or "Tool") .. " vendor" }
    end
    if not info then return false end
    local mine = myPos()
    local list = self:Candidates(kind, arg)
    if #list == 0 then
        local hint = ({
            pin = "no map pin set (ctrl+click on the world map)",
            corpse = "no corpse found on this map",
            vendor = "no vendor known on this continent yet - open a vendor window once",
            tool = "no vendor of this tool known for your faction",
            repair = "no repair vendor known yet - open a repairing vendor once",
            mailbox = "no mailbox learned yet - open one once",
            inn = "no inn learned yet - bind your hearthstone once",
        })[kind] or "no known place of this kind"
        OMQ:Print(info.label .. ": " .. hint)
        return false
    end
    sortByDistance(list, mine)
    dest = { kind = kind, arg = arg, label = info.label, cands = list, idx = 1, manual = false }
    OMQ:Fire("GUIDE_CHANGED", kind)
    return true
end

-- A fixed target (meeting point, shared pin or corpse of a group member).
-- tag: "meet" | "pin" | "corpse"; src: guid of the player it came from.
-- opts (decision 295): { name = shown under the label, radius = arrival in yards }
function G:StartAt(label, a, b, inst, tag, src, opts)
    if not OMQ:Master("guidance") then return end
    opts = opts or {}
    dest = { kind = "point", tag = tag, src = src, label = label, radius = opts.radius,
             cands = { { name = opts.name or label, a = a, b = b, inst = inst } }, idx = 1 }
    OMQ:Fire("GUIDE_CHANGED", "point")
end

function G:Clear()
    if dest then
        dest = nil
        OMQ:Fire("GUIDE_CHANGED", nil)
    end
end

function G:IsActive() return dest ~= nil end
function G:Kind()
    if not dest then return nil end
    if dest.kind == "point" then return dest.tag end
    if dest.arg then return dest.kind .. ":" .. dest.arg end
    return dest.kind
end

-- next candidate of the same kind (left click on the arrow); step -1 goes back (shift + left click)
function G:Cycle(step)
    if not dest or #dest.cands < 2 then return end
    dest.idx = ((dest.idx - 1 + (step or 1)) % #dest.cands) + 1
    dest.manual = true
end

-- Display state for the arrow, or nil when nothing is active.
-- { label, name, distance, heading, otherZone, ratio, count, idx }
function G:Current()
    if not dest then return nil end
    if IsInInstance and IsInInstance() then return nil end
    local mine = myPos()
    if not mine then return nil end
    -- pin and corpse can move: refresh them
    if dest.kind == "pin" or dest.kind == "corpse" then
        local fresh = self:Candidates(dest.kind, dest.arg)
        if #fresh == 0 then
            self:Clear()
            return nil
        end
        dest.cands = fresh
        dest.idx = 1
    end
    for _, c in ipairs(dest.cands) do c.d = distance(mine, c) end
    -- unless the player picked one, follow the nearest
    if not dest.manual and #dest.cands > 1 then
        local best, bi
        for i, c in ipairs(dest.cands) do
            if c.d and (not best or c.d < best) then best, bi = c.d, i end
        end
        if bi then dest.idx = bi end
    end
    local c = dest.cands[dest.idx]
    if not c then self:Clear(); return nil end
    if c.d and c.d <= (dest.radius or ARRIVE_YARDS) then
        self:Clear()
        return nil
    end
    -- the NPC's function in brackets after the name (decision 188): from the data, else the kind
    local shownName = c.name or dest.label
    local title = c.title or (c.name and dest.kind ~= "point" and dest.kind ~= "pin" and dest.kind ~= "corpse" and dest.label) or nil
    if c.name and title and title ~= c.name then shownName = c.name .. " (" .. title .. ")" end
    local st = { label = dest.label, name = shownName, distance = c.d,
                 otherZone = c.d == nil, count = #dest.cands, idx = dest.idx }
    if c.d and OMQ.Arrow then st.heading = OMQ.Arrow.Heading(c.a - mine.a, c.b - mine.b) end
    return st
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
OMQ:RegisterCommand("go", function(arg)
    arg = (arg or ""):lower()
    if arg == "" then
        local out = {}
        for _, k in ipairs(G.kinds) do out[#out + 1] = k.id end
        OMQ:Print("/omq go <" .. table.concat(out, "|") .. "|off>")
        return
    end
    if arg == "off" or arg == "stop" then G:Clear(); OMQ:Print("guidance cancelled"); return end
    if arg == "here" or arg == "meet" then G:SetMeetingPoint(); return end
    if not KIND[arg] then OMQ:Print("unknown destination: " .. arg); return end
    G:Start(arg)
end, "guidance: /omq go trainer|vendor|repair|auction|bank|flight|mailbox|inn|pin|corpse|off")

-- Prints what the fixed database resolves to (for checking the data in game).
OMQ:RegisterCommand("goinfo", function()
    local mine = myPos()
    local out = { "Guidance candidates" }
    for _, k in ipairs(G.kinds) do
        local list = G:Candidates(k.id)
        sortByDistance(list, mine)
        out[#out + 1] = string.format("%s (%d)", k.label, #list)
        for i = 1, math.min(#list, 4) do
            local c = list[i]
            out[#out + 1] = string.format("  %s  %s", c.name or "?", c.d and string.format("%d yd", c.d) or "other continent")
        end
    end
    OMQ:ShowReport(out)
end, "list the nearest guidance targets per kind")

----------------------------------------------------------------------
-- Sharing with the group (message "G")
--   G|proto|set|tag|guid|name|a|b|inst     tag = meet | pin (the corpse stays private)
--   G|proto|clr|tag|guid
----------------------------------------------------------------------
local TAG_LABEL = { meet = "Meeting point", pin = "Map pin", corpse = "Corpse" }

local function sendSet(tag, a, b, inst)
    local me = OMQ:GetSelf()
    if not me or (tag == "pin" and OMQ.db.guide.share == false) or not OMQ:Master("guidance") then return end
    OMQ:Send("G", "set", tag, me.guid, me.name or "?", string.format("%.1f", a), string.format("%.1f", b), tostring(inst or 0))
end

local function sendClear(tag)
    local me = OMQ:GetSelf()
    if not me or (tag == "pin" and OMQ.db.guide.share == false) or not OMQ:Master("guidance") then return end
    OMQ:Send("G", "clr", tag, me.guid)
end

OMQ:RegisterMessage("G", function(f)
    local op, tag, guid = f[1], f[2], f[3]
    local me = OMQ:GetSelf()
    if not (op and tag and guid) or (me and guid == me.guid) then return end
    if OMQ.db.guide.receive == false or not OMQ:Master("guidance") then return end
    if op == "set" then
        local a, b = tonumber(f[5]), tonumber(f[6])
        if not (a and b) or not TAG_LABEL[tag] or tag == "corpse" then return end
        local who = (f[4] and f[4] ~= "") and f[4] or "?"
        local label = tag == "corpse" and (who .. "'s corpse")
            or (TAG_LABEL[tag] .. " (" .. who .. ")")
        G:StartAt(label, a, b, tonumber(f[7]) or 0, tag, guid)
    elseif op == "clr" then
        if dest and dest.kind == "point" and dest.tag == tag and dest.src == guid then G:Clear() end
    end
end)

function G:SetMeetingPoint()
    local p = myPos()
    if not p then OMQ:Print("no position available"); return end
    G:StartAt("Meeting point", p.a, p.b, p.inst, "meet", nil)
    sendSet("meet", p.a, p.b, p.inst)
end

local function onPinChanged()
    local c = pinCandidates()[1]
    if c then
        G:Start("pin")
        sendSet("pin", c.a, c.b, c.inst)
    else
        if dest and dest.kind == "pin" then G:Clear() end
        sendClear("pin")
    end
end

-- The corpse arrow starts when the player releases the spirit (ghost), not at
-- the moment of death: lying on the body would end it at once.
local deathSpot
local function isGhost()
    if UnitIsGhost then return UnitIsGhost("player") and true or false end
    return UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") and true or false
end

local function onDeath()
    deathSpot = myPos()
end

local function onRevive()
    deathSpot = nil
    if dest and dest.kind == "point" and dest.tag == "corpse" and not dest.src then G:Clear() end
end

local function onAlive()
    if isGhost() then
        if deathSpot then
            G:StartAt("My corpse", deathSpot.a, deathSpot.b, deathSpot.inst, "corpse", nil)
        else
            G:Start("corpse")      -- logged in as a ghost: ask the game for the corpse
        end
    else
        onRevive()
    end
end

local ev = CreateFrame("Frame")
local HANDLERS = {
    USER_WAYPOINT_UPDATED = onPinChanged,
    PLAYER_DEAD = onDeath,
    PLAYER_ALIVE = onAlive,
    PLAYER_UNGHOST = onRevive,
}
for e in pairs(HANDLERS) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event)
    local ok, err = pcall(HANDLERS[event])
    if not ok then OMQ:Error("guide " .. event, err) end
end)
