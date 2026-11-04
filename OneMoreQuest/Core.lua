-- One More Quest: Core
-- Namespace, event bus, saved variables, player identity.
local ADDON, OMQ = ...
OMQ = OMQ or {}
_G.OneMoreQuest = OMQ

OMQ.name = "One More Quest"
OMQ.version = "1.2.2"

-- the last bag to look into for what I carry: the reagent bag too, if the client has one (decision 272)
function OMQ.LastBag()
    local n = NUM_BAG_SLOTS or 4
    local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    if type(reagent) == "number" and reagent > n then n = reagent end
    if type(NUM_TOTAL_EQUIPPED_BAG_SLOTS) == "number" and NUM_TOTAL_EQUIPPED_BAG_SLOTS > n then n = NUM_TOTAL_EQUIPPED_BAG_SLOTS end
    return n
end
OMQ.protocol = 1

----------------------------------------------------------------------
-- Defaults and saved variables
----------------------------------------------------------------------
local DEFAULTS = {
    minimap = { angle = 150, hidden = false },     -- default layout (decision 190)
    options = {
        questSync = true,
        autoShare = true,
        snoozeUntil = 0,
        buffOnlyAddon = false,
        compare = true,
        needs = true,
        qtrack = true,               -- group quest tracker (decision 149)
        sound = false,               -- soft sounds, off by default (decision 185)
        master = { alerts = true, group = true, guidance = true, vendor = true, chat = true },
        chatWords = "",
        qol = { repair = true, junk = true, water = true, ammo = true, flight = true, openmail = true, closemail = false },
    },
    alerts = { enabled = {}, lenientRank = false },
    arrow = { threshold = 120, enabled = true, style = 1 },     -- style: decision 192
    guide = { bar = true, receive = true, share = true, sharePlaces = true },
    quests = { ignored = {}, titles = {} },
}

local function copyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            copyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function OMQ:InitDB()
    OMQDB = OMQDB or {}
    copyDefaults(DEFAULTS, OMQDB)
    self.db = OMQDB
end

----------------------------------------------------------------------
-- Small event bus: modules talk through this, not through each other
----------------------------------------------------------------------
local handlers = {}

function OMQ:On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
end

function OMQ:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then self:Error(event, err) end
    end
end

----------------------------------------------------------------------
-- Output helpers
----------------------------------------------------------------------
function OMQ:Print(msg)
    print("|cffe2b64bOne More Quest:|r " .. tostring(msg))
end

function OMQ:Error(where, err)
    -- Never spam; keep the last errors for /omq debug
    self.errors = self.errors or {}
    table.insert(self.errors, tostring(where) .. ": " .. tostring(err))
    if #self.errors > 20 then table.remove(self.errors, 1) end
end

----------------------------------------------------------------------
-- Identity. Characters have two-part names on WoW Forever, so players
-- are always identified by GUID, never by name.
----------------------------------------------------------------------
function OMQ:GetSelf()
    if self.me then return self.me end
    local guid = UnitGUID("player")
    if not guid then return nil end
    local first, second = UnitName("player")
    local _, classToken = UnitClass("player")
    self.me = {
        guid = guid,
        name = first or "?",
        fullName = second and second ~= "" and (first .. " " .. second) or first,
        class = classToken,
        version = self.version,
        isSelf = true,
    }
    return self.me
end

----------------------------------------------------------------------
-- Slash commands. "/omq" alone is reserved for the vote (step 8).
----------------------------------------------------------------------
local commands = {}

function OMQ:RegisterCommand(name, fn, help, hidden)
    commands[name] = { fn = fn, help = help, hidden = hidden }
end

-- Master switches of the option categories (alerts, group, guidance, vendor)
function OMQ:Master(name)
    local m = OMQ.db and OMQ.db.options and OMQ.db.options.master
    return not m or m[name] ~= false
end

function OMQ:QuestSyncOn()
    return OMQ:Master("group") and OMQ.db.options.questSync and true or false
end

-- automatic sharing (the leader pushes, the others accept silently) needs quest sync too
function OMQ:QuestShareOn()
    return OMQ:QuestSyncOn() and OMQ.db.options.autoShare ~= false
end

-- Runs a registered command from code (used by the options windows)
function OMQ:RunCommand(name, arg)
    local c = commands[name]
    if c then
        local ok, err = pcall(c.fn, arg or "")
        if not ok then OMQ:Error("/omq " .. name, err) end
    end
end

SLASH_ONEMOREQUEST1 = "/omq"
SlashCmdList["ONEMOREQUEST"] = function(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    local cmd, rest = input:match("^(%S+)%s*(.*)$")
    if not cmd then
        OMQ:Fire("SLASH_EMPTY")
        return
    end
    cmd = cmd:lower()
    if cmd == "help" then
        OMQ:Print("commands:")
        local names = {}
        for n, c in pairs(commands) do if not c.hidden then names[#names + 1] = n end end
        table.sort(names)
        for _, n in ipairs(names) do
            print("  /omq " .. n .. " - " .. (commands[n].help or ""))
        end
        return
    end
    local c = commands[cmd]
    if c then
        local ok, err = pcall(c.fn, rest)
        if not ok then OMQ:Error("/omq " .. cmd, err); OMQ:Print("error: " .. tostring(err)) end
    else
        OMQ:Print("unknown command. Type /omq help")
    end
end

OMQ:RegisterCommand("debug", function()
    local me = OMQ:GetSelf()
    OMQ:Print("version " .. OMQ.version .. ", protocol " .. OMQ.protocol)
    if me then print("  me: " .. me.name .. " (" .. tostring(me.class) .. ") " .. me.guid) end
    local n = 0
    for _ in pairs(OMQ.users or {}) do n = n + 1 end
    print("  addon users known: " .. n)
    print("  errors: " .. #(OMQ.errors or {}))
    for _, e in ipairs(OMQ.errors or {}) do print("   " .. e) end
end, "show internal state")

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        OMQ:InitDB()
        OMQ:Fire("DB_READY")
    elseif event == "PLAYER_LOGIN" then
        OMQ:GetSelf()
        OMQ:Fire("READY")
    end
end)
