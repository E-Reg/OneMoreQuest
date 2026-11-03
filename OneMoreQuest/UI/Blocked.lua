-- One More Quest: watch for blocked actions ("Interface action failed because of an AddOn")
-- The game names the function it refused (e.g. "OneMoreQuestAlerts:Hide()") only in the events
-- ADDON_ACTION_BLOCKED and ADDON_ACTION_FORBIDDEN; its own message comes once per session and says nothing more.
-- Every such event is kept (the last 30, across reloads in OMQDB.blockedLog) with the time, the combat state
-- and the seconds since the combat started; the first one of each function is printed in the chat.
-- /omq blocked: the log; "clear" empties it; "taintlog on|off" switches the game's taint log
-- (Logs\taint.log, written after a /reload, with the full call stack).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local B = {}
OMQ.Blocked = B

local MAX = 30
local entries = {}
local said = {}
local combatSince = nil

local function now() return GetTime and GetTime() or 0 end
local function locked() return InCombatLockdown and InCombatLockdown() and true or false end

local function trim()
    while #entries > MAX do table.remove(entries, 1) end
end

function B.Record(event, addon, func)
    local e = {
        event = tostring(event),
        addon = tostring(addon),
        func = tostring(func),
        combat = locked(),
        at = date and date("%Y-%m-%d %H:%M:%S") or "?",
        sinceCombat = combatSince and math.floor((now() - combatSince) * 10 + 0.5) / 10 or nil,
        version = OMQ.version,
    }
    entries[#entries + 1] = e
    trim()
    if OMQ.db then OMQ.db.blockedLog = entries end
    if not said[e.func] then
        said[e.func] = true
        OMQ:Print("blocked action: " .. e.func .. " (" .. B.Where(e) .. "). /omq blocked shows the log")
    end
    return e
end

function B.Where(e)
    if e.combat then
        return "in combat" .. (e.sinceCombat and (", " .. e.sinceCombat .. " s after the start") or "")
    end
    return "out of combat"
end

function B.Log() return entries end

function B.Report()
    local lines = {}
    if #entries == 0 then
        lines[1] = "blocked actions: none recorded"
    else
        lines[1] = "blocked actions (" .. #entries .. ", newest last):"
        for i = math.max(1, #entries - 9), #entries do
            local e = entries[i]
            lines[#lines + 1] = string.format("%s %s %s: %s (%s)%s", e.at, (e.event:gsub("^ADDON_ACTION_", "")), e.addon,
                e.func, B.Where(e), e.version and (" v" .. e.version) or "")
        end
    end
    local tl = GetCVar and GetCVar("taintLog")
    lines[#lines + 1] = "game taint log: " .. tostring(tl or "?") .. " (/omq blocked taintlog on, then /reload)"
    for _, s in ipairs(lines) do OMQ:Print(s) end
    return lines
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, addon, func)
    if event == "PLAYER_REGEN_DISABLED" then combatSince = now(); return end
    if event == "PLAYER_REGEN_ENABLED" then combatSince = nil; return end
    local ok, err = pcall(B.Record, event, addon, func)
    if not ok then OMQ:Error("blocked", err) end
end)

OMQ:On("DB_READY", function()
    -- the log of the sessions before comes first; what happened during the load is added behind it
    local old = type(OMQ.db.blockedLog) == "table" and OMQ.db.blockedLog or {}
    if old ~= entries then
        for _, e in ipairs(entries) do old[#old + 1] = e end
        entries = old
        trim()
    end
    OMQ.db.blockedLog = entries
end)

OMQ:RegisterCommand("blocked", function(arg)
    local cmd, value = (arg or ""):match("^(%S*)%s*(.-)$")
    if cmd == "clear" then
        for i = #entries, 1, -1 do entries[i] = nil end
        said = {}
        OMQ:Print("blocked actions: log cleared")
    elseif cmd == "taintlog" then
        local level = (value == "off" or value == "0") and "0" or "1"
        if SetCVar then pcall(SetCVar, "taintLog", level) end
        OMQ:Print("game taint log " .. (level == "1" and "on: /reload, play until the message comes, then see Logs\\taint.log"
            or "off"))
    else
        B.Report()
    end
end, "blocked actions (Interface action failed): the log; 'clear'; 'taintlog on|off'")
