-- One More Quest: flight times
-- Measures every flight path (from the node you start at to the node you picked) and keeps the time account-wide
-- in OMQDB.taxi. A route never flown yet takes its known time from OMQ.taxiTimes (Data/TaxiTimes.lua), else an estimate from the length of its hops on the taxi map, at the speed
-- learned from the measured flights (marked with "~"). Measured times are shared with the dads in the group
-- (message TT: "from-to:seconds" pairs); a time of my own always wins over a shared one.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local X = {}
OMQ.Taxi = X

X.DEFAULT_RATE = 0.036        -- seconds per yard before anything was measured (about 28 yards per second)
X.START_WINDOW = 10           -- seconds between the click on a node and the start of the flight
X.MIN_FLIGHT = 10             -- shorter flights are not measured
X.SHARE_EVERY = 600           -- the full list goes to a group at most every 10 minutes
X.PER_MESSAGE = 15

local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function str(v) return type(v) == "string" and ok(v) and v ~= "" end
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2)
end

X.diag = {}
local function note(k) X.diag[k] = (X.diag[k] or 0) + 1 end

function X:Store()
    if not OMQDB then return nil end
    OMQDB.taxi = OMQDB.taxi or {}
    return OMQDB.taxi
end
local function key(a, b) return tostring(a) .. "-" .. tostring(b) end
X.Key = key

----------------------------------------------------------------------
-- The taxi map: nodes, the route and its length
----------------------------------------------------------------------
-- the map the taxi nodes are on: the taxi map, else the continent the player is on (Classic has no GetTaxiMapID)
local function taxiMap()
    local id = GetTaxiMapID and call(GetTaxiMapID)
    if num(id) and id > 0 then return id end
    local m = C_Map and C_Map.GetBestMapForUnit and call(C_Map.GetBestMapForUnit, "player")
    for _ = 1, 8 do
        if not num(m) then break end
        local info = C_Map.GetMapInfo and call(C_Map.GetMapInfo, m)
        if type(info) ~= "table" then break end
        if info.mapType == 2 then return m end
        m = info.parentMapID
    end
    return nil
end
X._TaxiMap = taxiMap
-- slot index -> node id: from the taxi map, else from the English node name (names when nothing fits)
local function nodeIds()
    local out = {}
    local mapID = taxiMap()
    local list = C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and num(mapID) and call(C_TaxiMap.GetAllTaxiNodes, mapID)
    if type(list) == "table" then
        for _, n in ipairs(list) do
            if num(n.slotIndex) and num(n.nodeID) then out[n.slotIndex] = n.nodeID end
        end
    end
    return out, mapID
end
local function idOf(ids, slot)
    if ids[slot] then return ids[slot] end
    local nm = TaxiNodeName and call(TaxiNodeName, slot)
    if not str(nm) then return nil end
    local fac = UnitFactionGroup and call(UnitFactionGroup, "player")
    local byName = OMQ.taxiNodeIds and str(fac) and OMQ.taxiNodeIds[fac]
    local id = byName and byName[nm:match("^([^,]+)") or nm]
    if num(id) then note("id.byname"); return id end
    return nm
end
local function currentSlot()
    local n = NumTaxiNodes and call(NumTaxiNodes)
    if not num(n) then return nil end
    for i = 1, n do
        if TaxiNodeGetType and call(TaxiNodeGetType, i) == "CURRENT" then return i end
    end
end
-- yards of the hops to `slot`, from the taxi map coordinates (0..1) and the map's size
local function yards(slot, mapID)
    local hops = GetNumRoutes and call(GetNumRoutes, slot)
    if not num(hops) or hops < 1 then return nil end
    local w, h
    if C_Map and C_Map.GetMapWorldSize and num(mapID) then w, h = call(C_Map.GetMapWorldSize, mapID) end
    if not (num(w) and num(h)) and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D and num(mapID) then
        -- Classic: the world size from the positions of two map corners
        local _, a = call(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0, 0))
        local _, b = call(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(1, 1))
        if type(a) == "table" and type(b) == "table" and a.GetXY and b.GetXY then
            local ax, ay = a:GetXY()
            local bx, by = b:GetXY()
            if num(ax) and num(bx) then w, h = math.abs(by - ay), math.abs(bx - ax) end
        end
    end
    if not (num(w) and num(h) and w > 0 and h > 0) then return nil end
    local total = 0
    for i = 1, hops do
        local sx, sy = call(TaxiGetSrcX, slot, i), call(TaxiGetSrcY, slot, i)
        local dx, dy = call(TaxiGetDestX, slot, i), call(TaxiGetDestY, slot, i)
        if not (num(sx) and num(sy) and num(dx) and num(dy)) then return nil end
        total = total + math.sqrt(((dx - sx) * w) ^ 2 + ((dy - sy) * h) ^ 2)
    end
    return total > 0 and total or nil
end
X._Yards = yards

-- seconds per yard from my own measured flights
function X:Rate()
    local s, y = 0, 0
    for _, r in pairs(self:Store() or {}) do
        if r.me and num(r.y) and r.y > 0 then s, y = s + r.s, y + r.y end
    end
    if y < 500 then return self.DEFAULT_RATE end
    return s / y
end

-- seconds for a route and whether it is only an estimate
function X:Time(from, to, yd)
    local r = (self:Store() or {})[key(from, to)]
    if r and num(r.s) then return r.s, false end
    local known = OMQ.taxiTimes and OMQ.taxiTimes[key(from, to)]
    if num(known) then return known, false end
    if num(yd) then return math.floor(yd * self:Rate() + 0.5), true end
    return nil
end

----------------------------------------------------------------------
-- A flight
----------------------------------------------------------------------
-- the click on a destination (hooked TakeTaxiNode)
function X:Picked(slot)
    if not num(slot) then return end
    local ids, mapID = nodeIds()
    local from = currentSlot()
    local a, b = from and idOf(ids, from), idOf(ids, slot)
    if not (a and b) then note("pick.noid"); return end
    local nm = TaxiNodeName and call(TaxiNodeName, slot)
    local yd = yards(slot, mapID)
    self.pending = { from = a, to = b, name = str(nm) and (nm:match("^([^,]+)") or nm) or nil, y = yd, at = GetTime() }
    note("pick")
end

function X:Started()
    local p = self.pending
    self.pending = nil
    if not p or GetTime() - p.at > self.START_WINDOW then self.flight = { at = GetTime() }; note("start.unknown"); return end
    local secs, est = self:Time(p.from, p.to, p.y)
    self.flight = { from = p.from, to = p.to, name = p.name, y = p.y, at = GetTime(), secs = secs, est = est }
    note("start")
    OMQ:Fire("TAXI_CHANGED")
end

function X:Landed()
    local f = self.flight
    self.flight = nil
    if not f then return end
    OMQ:Fire("TAXI_CHANGED")
    if not f.from then return end
    local took = math.floor(GetTime() - f.at + 0.5)
    if took < self.MIN_FLIGHT then note("land.short"); return end
    local store = self:Store()
    if not store then return end
    local k = key(f.from, f.to)
    local r = store[k]
    if r and r.me then
        r.s = math.floor((r.s * r.n + took) / (r.n + 1) + 0.5)
        r.n = r.n + 1
    else
        r = { s = took, n = 1, me = true }
        store[k] = r
    end
    if num(f.y) then r.y = math.floor(f.y + 0.5) end
    r.t = time()
    note("measured")
    self:Share({ k })
end

-- seconds left of the current flight (nil when not known), and whether it is an estimate
function X:Left()
    local f = self.flight
    if not (f and f.secs) then return nil end
    return math.max(0, f.secs - (GetTime() - f.at)), f.est
end

----------------------------------------------------------------------
-- Sharing between dads
----------------------------------------------------------------------
function X:Share(keys)
    local store = self:Store()
    if not (store and OMQ.GetChannel and OMQ:GetChannel()) then return 0 end
    if not keys then
        keys = {}
        for k, r in pairs(store) do if r.me then keys[#keys + 1] = k end end
        table.sort(keys)
    end
    local sent, part = 0, {}
    local function flush()
        if #part > 0 then OMQ:SendBulk("TT", table.concat(part, ",")); sent = sent + 1; part = {} end
    end
    for _, k in ipairs(keys) do
        local r = store[k]
        if r and r.me and k:match("^%d+%-%d+$") then
            part[#part + 1] = k .. ":" .. r.s
            if #part >= self.PER_MESSAGE then flush() end
        end
    end
    flush()
    return sent
end

local function onTimes(fields, sender)
    local store = X:Store()
    if not store then return end
    for pair in tostring(fields[1] or ""):gmatch("[^,]+") do
        local k, s = pair:match("^([^:]+):(%d+)$")
        s = tonumber(s)
        if k and k:match("^%d+%-%d+$") and s and s >= X.MIN_FLIGHT and s < 3600 and not (store[k] and store[k].me) then
            store[k] = { s = s, n = 1, t = time() }
            note("shared.in")
        end
    end
end
X._OnTimes = onTimes
OMQ:RegisterMessage("TT", onTimes)

function X:Roster()
    if not (OMQ.GetChannel and OMQ:GetChannel()) then return end
    local any = false
    for g in pairs(OMQ.users or {}) do if OMQ.InGroup and OMQ:InGroup(g) then any = true; break end end
    if not any then return end
    if self.sharedAt and GetTime() - self.sharedAt < self.SHARE_EVERY then return end
    self.sharedAt = GetTime()
    self:Share()
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
function X:Tick()
    local taxi = UnitOnTaxi and call(UnitOnTaxi, "player") and true or false
    if taxi and not self.wasTaxi then self:Started() elseif not taxi and self.wasTaxi then self:Landed() end
    self.wasTaxi = taxi
end

if hooksecurefunc and _G.TakeTaxiNode then
    hooksecurefunc("TakeTaxiNode", function(slot) pcall(X.Picked, X, slot) end)
end

local frame = CreateFrame("Frame")
pcall(frame.RegisterEvent, frame, "GROUP_ROSTER_UPDATE")
frame:SetScript("OnEvent", function()
    if C_Timer and C_Timer.After then C_Timer.After(5, function() pcall(X.Roster, X) end) end
end)

OMQ:On("READY", function()
    C_Timer.NewTicker(1, function()
        local fine, err = pcall(X.Tick, X)
        if not fine then note("err.tick"); OMQ:Error("taxi tick", err) end
    end)
end)

OMQ:RegisterCommand("taxi", function()
    local store = X:Store() or {}
    local mine, shared = 0, 0
    for _, r in pairs(store) do if r.me then mine = mine + 1 else shared = shared + 1 end end
    local known = 0
    for _ in pairs(OMQ.taxiTimes or {}) do known = known + 1 end
    OMQ:Print(string.format("taxi: %d routes measured, %d from dads, %d known, %.3f s/yd", mine, shared, known, X:Rate()))
    print("  map " .. tostring(taxiMap()) .. ", GetTaxiMapID " .. tostring(GetTaxiMapID ~= nil) .. ", GetAllTaxiNodes " .. tostring(C_TaxiMap and C_TaxiMap.GetAllTaxiNodes ~= nil))
    local f = X.flight
    if f then print("  flying " .. tostring(f.from) .. " -> " .. tostring(f.to) .. " " .. tostring(f.name) .. ", " .. tostring(f.secs) .. (f.est and " (estimate)" or "")) end
    local keys = {}
    for k, v in pairs(X.diag) do keys[#keys + 1] = k .. "=" .. v end
    table.sort(keys)
    print("  diag " .. (#keys > 0 and table.concat(keys, " ") or "-"))
end, nil, true)
