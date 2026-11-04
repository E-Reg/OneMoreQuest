-- One More Quest: follow the group's flight
-- When a group member with the addon takes a flight path, everybody else is
-- told. Whoever opens a flight master within 60 seconds flies to the same
-- destination automatically. Message "F": F|proto|guid|name|destination|x|y
-- Node names depend on the client language (English / German), so the
-- destination is identified by its position on the taxi map; the name is only
-- used for display and as a fallback.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local FOLLOW_SECONDS = 60

local F = {}
OMQ.Flight = F

local pending = nil      -- { dest, who, guid, at }

local function enabled()
    local o = OMQ.db and OMQ.db.options and OMQ.db.options.qol
    return OMQ:Master("group") and (not o or o.flight ~= false)
end

local function nodeName(i)
    if TaxiNodeName then
        local ok, n = pcall(TaxiNodeName, i)
        if ok and type(n) == "string" and not (issecretvalue and issecretvalue(n)) then return n end
    end
end

local function nodePos(i)
    if TaxiNodePosition then
        local ok, x, y = pcall(TaxiNodePosition, i)
        if ok and type(x) == "number" and type(y) == "number"
            and not (issecretvalue and (issecretvalue(x) or issecretvalue(y))) then
            return x, y
        end
    end
end

local function nodeType(i)
    if TaxiNodeGetType then
        local ok, t = pcall(TaxiNodeGetType, i)
        if ok then return t end
    end
end

----------------------------------------------------------------------
-- Sending: a flight was started by this player
----------------------------------------------------------------------
local lastSent, lastSentAt = nil, 0
local function onTakeTaxi(slot)
    if not enabled() then return end
    local dest = nodeName(slot)
    if not dest then return end
    local now = GetTime()
    if dest == lastSent and now - lastSentAt < 5 then return end
    lastSent, lastSentAt = dest, now
    local me = OMQ:GetSelf()
    if not me then return end
    local x, y = nodePos(slot)
    OMQ:Send("F", me.guid, me.name or "?", dest, x and string.format("%.4f", x) or "-", y and string.format("%.4f", y) or "-")
end

----------------------------------------------------------------------
-- Receiving
----------------------------------------------------------------------
OMQ:RegisterMessage("F", function(f)
    local guid, who, dest = f[1], f[2], f[3]
    local me = OMQ:GetSelf()
    if not (guid and dest and dest ~= "") or (me and guid == me.guid) then return end
    if not enabled() then return end
    if UnitOnTaxi and UnitOnTaxi("player") then return end
    pending = { dest = dest, who = (who and who ~= "") and who or "?", guid = guid, at = GetTime(),
                x = tonumber(f[4]), y = tonumber(f[5]) }
    OMQ:Fire("FLIGHT_PENDING")
    if OMQ.Alerts then OMQ.Alerts:Evaluate() end
end)

-- decision 242: a dad who is not at a flight master gets a card; a click leads the arrow to the
-- nearest flight master and keeps the follow open for 5 minutes, so he can still get there
F.LONG_WINDOW = 300
function F:Extend()
    if pending then pending.window = math.max(pending.window or FOLLOW_SECONDS, (GetTime() - pending.at) + F.LONG_WINDOW) end
end
if OMQ.Alerts then
    OMQ.Alerts:Register({ id = "flightfollow", name = "A dad took a flight: follow him", check = function()
        local p = F:Pending()
        if not p or not enabled() or (UnitOnTaxi and UnitOnTaxi("player")) then return nil end
        if TaxiFrame and TaxiFrame.IsShown and TaxiFrame:IsShown() then return nil end
        return { {
            key = "flight:" .. (p.guid or "") .. ":" .. math.floor(p.at),
            title = p.who .. " flies to " .. p.dest, tag = "FLIGHT",
            sub = "Click: arrow to the nearest flight master - you follow him there",
            text = p.who .. " flies to " .. p.dest, go = "flight",
            icon = "Interface\\Icons\\Ability_Mount_Gryphon_01", color = { 0.89, 0.71, 0.29 },
            open = function() F:Extend() end,
        } }
    end })
end

function F:Pending()
    if pending and GetTime() - pending.at > (pending.window or FOLLOW_SECONDS) then pending = nil end
    return pending
end

----------------------------------------------------------------------
-- Following: the flight master window opens
----------------------------------------------------------------------
local function follow()
    local p = F:Pending()
    if not p then return end
    if not (NumTaxiNodes and TakeTaxiNode) then
        OMQ:Print("flight: this client has no taxi functions")
        return
    end
    local found
    for i = 1, NumTaxiNodes() do
        local match
        if p.x and p.y then
            local x, y = nodePos(i)
            match = x and math.abs(x - p.x) < 0.003 and math.abs(y - p.y) < 0.003
        else
            match = nodeName(i) == p.dest      -- fallback: same language only
        end
        if match then
            local t = nodeType(i)
            if t == nil or t == "REACHABLE" then found = i end
            break
        end
    end
    if found then
        pending = nil
        OMQ:Fire("FLIGHT_PENDING")
        local ok, err = pcall(TakeTaxiNode, found)
        if not ok then OMQ:Error("flight", err) end
    else
        OMQ:Print("flight: cannot fly to " .. p.dest .. " from here (not known or not reachable)")
        pending = nil
        OMQ:Fire("FLIGHT_PENDING")
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("TAXIMAP_OPENED")
frame:SetScript("OnEvent", function()
    if not enabled() or not F:Pending() then return end
    -- give the taxi window a moment to fill its node list
    local function run() local ok, err = pcall(follow); if not ok then OMQ:Error("flight", err) end end
    if C_Timer and C_Timer.After then C_Timer.After(0.3, run) else run() end
end)

OMQ:On("READY", function()
    if hooksecurefunc and TakeTaxiNode then
        hooksecurefunc("TakeTaxiNode", function(slot)
            local ok, err = pcall(onTakeTaxi, slot)
            if not ok then OMQ:Error("flight hook", err) end
        end)
    end
end)

-- Test hooks / diagnostics
F._onTakeTaxi = onTakeTaxi

OMQ:RegisterCommand("taxi", function()
    local out = { "Flight follow" }
    out[#out + 1] = "TakeTaxiNode: " .. tostring(TakeTaxiNode ~= nil) .. ", NumTaxiNodes: " .. tostring(NumTaxiNodes ~= nil)
        .. ", TaxiNodeName: " .. tostring(TaxiNodeName ~= nil) .. ", TaxiNodeGetType: " .. tostring(TaxiNodeGetType ~= nil) .. ", TaxiNodePosition: " .. tostring(TaxiNodePosition ~= nil)
    local p = F:Pending()
    out[#out + 1] = p and string.format("pending: %s -> %s (%d s left)", p.who, p.dest,
        math.max(0, math.floor(FOLLOW_SECONDS - (GetTime() - p.at)))) or "pending: none"
    if NumTaxiNodes then
        local ok, n = pcall(NumTaxiNodes)
        if ok and n and n > 0 then
            out[#out + 1] = "nodes at this flight master: " .. n
            for i = 1, math.min(n, 40) do
                local x, y = nodePos(i)
                out[#out + 1] = string.format("  %d  %s  [%s]  %s, %s", i, tostring(nodeName(i)), tostring(nodeType(i)),
                    x and string.format("%.4f", x) or "?", y and string.format("%.4f", y) or "?")
            end
        end
    end
    OMQ:ShowReport(out)
end, "flight follow diagnostics (open a flight master first)")
