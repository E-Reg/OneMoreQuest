-- One More Quest: distance arrow (section 6)
-- Shown only to the straggler: when every other group member is farther away
-- than the threshold (or in another zone), an arrow points at one of them.
-- Positions are broadcast by every client (message "P"), so the arrow does not
-- depend on UnitPosition working for other players.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local POS_INTERVAL = 2          -- seconds between position messages
local POS_STALE = 8             -- a position older than this is ignored
local HIDE_SECONDS = 300        -- decision 7: right click hides for 5 minutes
local DEFAULT_THRESHOLD = 120   -- decision 4
local MAX_THRESHOLD = 500       -- decision 62
local TWO_PI = math.pi * 2

local A = {}
OMQ.Arrow = A

local arrowFrame, texture, detail, nameText, distText
local hideUntil = 0             -- memory only: a reload resets the timer (decision 39)
local selectedGuid, manual = nil, false
local moveMode = false

----------------------------------------------------------------------
-- Axis calibration
-- UnitPosition returns two world coordinates. Which one points where depends
-- on the client, so the code learns it from the player's own movement: while
-- running forward, the movement vector must match GetPlayerFacing().
-- Hypothesis (s, k): moveAngle = s * facing + k * pi / 2
----------------------------------------------------------------------
local HYP = {}
for _, s in ipairs({ -1, 1 }) do
    for k = 0, 3 do HYP[#HYP + 1] = { s = s, k = k } end
end
local votes = {}
for i = 1, #HYP do votes[i] = 0 end
local PRIOR = { s = -1, k = 1 }       -- first value = west, second = north
local cal = nil                       -- set when learned or loaded

local function angleDiff(a, b)
    local d = (a - b) % TWO_PI
    if d > math.pi then d = d - TWO_PI end
    return math.abs(d)
end

function A.CalibrationVote(da, db, facing)
    local moveAngle = math.atan2(db, da)
    for i, h in ipairs(HYP) do
        if angleDiff(moveAngle, h.s * facing + h.k * math.pi / 2) < 0.35 then
            votes[i] = votes[i] + 1
        end
    end
    -- pick a winner when it is clearly ahead
    local best, second, bestI = 0, 0, nil
    for i, v in ipairs(votes) do
        if v > best then second = best; best = v; bestI = i
        elseif v > second then second = v end
    end
    if bestI and best >= 15 and best >= second * 1.5 then
        cal = { s = HYP[bestI].s, k = HYP[bestI].k }
        if OMQ.db then OMQ.db.arrow.cal = { s = cal.s, k = cal.k } end
    end
end

function A.GetCalibration()
    return cal or PRIOR, cal ~= nil
end

-- Heading (counterclockwise from north, like GetPlayerFacing) of a vector.
function A.Heading(da, db)
    local h = A.GetCalibration()
    local theta = math.atan2(db, da)
    return (h.s * (theta - h.k * math.pi / 2)) % TWO_PI
end

----------------------------------------------------------------------
-- Own position
----------------------------------------------------------------------
local function myPosition()
    if not UnitPosition then return nil end
    local a, b, _, inst = UnitPosition("player")
    if type(a) ~= "number" or type(b) ~= "number" then return nil end
    if issecretvalue and (issecretvalue(a) or issecretvalue(b)) then return nil end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    return { a = a, b = b, inst = inst, map = map }
end

----------------------------------------------------------------------
-- Position messages
----------------------------------------------------------------------
local function sendPosition()
    local pos = myPosition()
    local me = OMQ:GetSelf()
    if not pos or not me then return end
    local others = false
    for guid in pairs(OMQ.users) do if guid ~= me.guid then others = true; break end end
    if not others then return end
    local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") and "1" or "0"
    local taxi = UnitOnTaxi and UnitOnTaxi("player") and "1" or "0"
    OMQ:Send("P", me.guid, string.format("%.1f", pos.a), string.format("%.1f", pos.b),
        tostring(pos.inst or 0), tostring(pos.map or 0), dead, taxi)
end

local function handlePosition(fields)
    local guid = fields[1]
    local u = guid and OMQ.users[guid]
    if not u then return end
    local a, b = tonumber(fields[2]), tonumber(fields[3])
    if not a or not b then return end
    u.pos = { a = a, b = b, inst = tonumber(fields[4]) or 0, map = tonumber(fields[5]) or 0,
              dead = fields[6] == "1", taxi = fields[7] == "1", at = GetTime() }
end
OMQ:RegisterMessage("P", handlePosition)

----------------------------------------------------------------------
-- Straggler logic (pure enough to test): returns the display state.
----------------------------------------------------------------------
-- state = { show = bool, reason = string, target = member, otherZone = bool,
--           distance = yards, ratio = distance / threshold }
local HYSTERESIS = 0.5         -- the arrow goes away again at 50 percent of the threshold
local wasShown = false

function A:Evaluate()
    local state = { show = false }
    local prevShown = wasShown
    wasShown = false
    local me = OMQ:GetSelf()
    local mine = myPosition()
    if not me or not mine then state.reason = "no position"; return state end
    if not (OMQ:GetChannel()) then state.reason = "not grouped"; return state end
    if OMQ.db.arrow.enabled == false or not OMQ:Master("guidance") then state.reason = "turned off"; return state end
    if IsInInstance and IsInInstance() then state.reason = "instance"; return state end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then state.reason = "dead"; return state end
    if UnitOnTaxi and UnitOnTaxi("player") then state.reason = "on a flight"; return state end

    local threshold = OMQ.db.arrow.threshold or DEFAULT_THRESHOLD
    local now = GetTime()
    local members = {}
    for guid, u in pairs(OMQ.users) do
        local p = u.pos
        if guid ~= me.guid and p and not p.dead and not p.taxi and (now - p.at) < POS_STALE and OMQ:IsOnline(u) then
            -- the world coordinates of one continent are shared by all its zones and cities, so
            -- the arrow points across zones; only another continent or an instance is out of reach
            -- (decision 216)
            local sameZone = p.inst == mine.inst
            local dist
            if p.inst == mine.inst then
                dist = math.sqrt((p.a - mine.a) ^ 2 + (p.b - mine.b) ^ 2)
            end
            members[#members + 1] = {
                guid = guid, name = u.name, class = u.class, pos = p,
                sameZone = sameZone, distance = dist,
            }
        end
    end
    -- inside a major city nobody needs an arrow to a member who is in a city too
    if mine.map and OMQ.cityMaps and OMQ.cityMaps[mine.map] then
        local kept, hidden = {}, false
        for _, m in ipairs(members) do
            if OMQ.cityMaps[m.pos.map] then hidden = true else kept[#kept + 1] = m end
        end
        members = kept
        if #members == 0 and hidden then state.reason = "everyone is in a major city"; return state end
    end
    table.sort(members, function(x, y) return (x.name or "") < (y.name or "") end)
    if #members == 0 then state.reason = "nobody to follow"; return state end

    local nearest
    for _, m in ipairs(members) do
        if m.sameZone and m.distance and (not nearest or m.distance < nearest.distance) then nearest = m end
    end
    local limit = prevShown and threshold * HYSTERESIS or threshold
    if nearest and nearest.distance <= limit then
        state.reason = "close enough"; state.members = members
        return state
    end
    state.members = members

    -- choose the target: manual choice if still valid, else nearest, else anybody
    local target
    if manual and selectedGuid then
        for _, m in ipairs(members) do if m.guid == selectedGuid then target = m end end
        if not target then manual = false end
    end
    target = target or nearest or members[1]
    selectedGuid = target.guid
    state.show = true
    wasShown = true
    state.target = target
    state.otherZone = not target.sameZone
    state.distance = target.distance
    state.ratio = target.distance and (target.distance / threshold) or 2
    state.heading = (not state.otherZone) and A.Heading(target.pos.a - mine.a, target.pos.b - mine.b) or nil
    return state
end

-- Distance in yards to an addon user (fresh position and same instance), or nil.
function A:DistanceTo(guid)
    local u = OMQ.users[guid]
    local mine = myPosition()
    if not (u and u.pos and mine) then return nil end
    if (GetTime() - u.pos.at) >= POS_STALE or u.pos.inst ~= mine.inst then return nil end
    return math.sqrt((u.pos.a - mine.a) ^ 2 + (u.pos.b - mine.b) ^ 2)
end

-- Left click: next member in list order (decision 3 and 66).
-- step = 1: the next member, -1: back to the one before (shift + left click, decision 188)
function A:CycleTarget(step)
    local state = self:Evaluate()
    local members = state.members
    if not members or #members == 0 then return end
    local idx = 0
    for i, m in ipairs(members) do if m.guid == selectedGuid then idx = i end end
    if idx == 0 and (step or 1) < 0 then idx = 1 end
    local nextMember = members[((idx - 1 + (step or 1)) % #members) + 1]
    selectedGuid, manual = nextMember.guid, true
end

-- true while the straggler arrow is on screen (as of the last evaluation)
function A:IsStragglerShown() return wasShown and true or false end

function A:HideForFiveMinutes()
    hideUntil = GetTime() + HIDE_SECONDS
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local function classColor(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function savePosition()
    local point, _, relPoint, x, y = arrowFrame:GetPoint()
    OMQ.db.arrow.point = { point or "CENTER", relPoint or "CENTER", x or 0, y or 120 }
end

local function applyPosition()
    local p = OMQ.db.arrow.point or { "CENTER", "CENTER", -11, 121 }
    arrowFrame:ClearAllPoints()
    arrowFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

-- arrow styles (decision 192): 1 war arrowhead (default), 2 rune chevrons, 3 compass needle, 4 crystal
A.STYLES = { "War arrowhead", "Rune chevrons", "Compass needle", "Crystal" }   -- Crystal: decision 209
function A:Style()
    local st = OMQ.db and OMQ.db.arrow and tonumber(OMQ.db.arrow.style) or 1
    return (st >= 1 and st <= #A.STYLES) and st or 1
end
function A:ApplyStyle()
    if not texture then return end
    local st = self:Style()
    texture:SetTexture("Interface\\AddOns\\OneMoreQuest\\Media\\Arrow" .. st .. "_Tint")
    detail:SetTexture("Interface\\AddOns\\OneMoreQuest\\Media\\Arrow" .. st .. "_Detail")
end
function A:SetStyle(st)
    OMQ.db.arrow.style = st
    self:ApplyStyle()
end
-- the three styles for the picker in the options (decision 197): name and the two texture layers
function A:StyleChoices()
    local out = {}
    for i, name in ipairs(A.STYLES) do
        out[i] = { label = name, tint = "Interface\\AddOns\\OneMoreQuest\\Media\\Arrow" .. i .. "_Tint",
                   detail = "Interface\\AddOns\\OneMoreQuest\\Media\\Arrow" .. i .. "_Detail" }
    end
    return out
end
function A:CycleStyle() self:SetStyle(self:Style() % #A.STYLES + 1) end

-- smooth turning (decision 193): render() only says where the arrow should point; every frame the
-- facing is read again and the arrow turns there along the shorter way, so it never jumps
local ARROW_SIZE = 58
local liveHeading, wantRot, shownRot = nil, 0, 0
local function rotate(r) liveHeading, wantRot = nil, r or 0 end
local function point(heading) liveHeading = heading end
local function turnStep(elapsed)
    local target = wantRot
    if liveHeading then
        local facing = GetPlayerFacing and GetPlayerFacing()
        if type(facing) ~= "number" then return end
        target = (liveHeading - facing) % TWO_PI
    end
    local diff = (target - shownRot + math.pi) % TWO_PI - math.pi
    local k = 1 - math.exp(-(elapsed or 0.016) * 22)
    if math.abs(diff) < 0.002 then shownRot = target else shownRot = (shownRot + diff * k) % TWO_PI end
    texture:SetRotation(shownRot)
    if detail then detail:SetRotation(shownRot) end
end
A._TurnStep = turnStep
function A:_Rotation() return shownRot, liveHeading, wantRot end

local function build()
    arrowFrame = CreateFrame("Button", "OneMoreQuestArrow", UIParent)
    arrowFrame:SetSize(115, 120)
    arrowFrame:SetFrameStrata("HIGH")
    arrowFrame:SetClampedToScreen(true)
    arrowFrame:SetMovable(true)
    arrowFrame:EnableMouse(true)
    arrowFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    arrowFrame:RegisterForDrag("LeftButton")

    -- no background: only the arrow and an outlined text
    -- the arrow in two layers (decision 192): the body takes the colour, the iron and gold details do not
    texture = arrowFrame:CreateTexture(nil, "ARTWORK")
    texture:SetSize(ARROW_SIZE, ARROW_SIZE)          -- 25 % smaller, same centre (decision 193)
    texture:SetPoint("TOP", 0, -4 - (77 - ARROW_SIZE) / 2)
    detail = arrowFrame:CreateTexture(nil, "OVERLAY")
    detail:SetAllPoints(texture)
    A:ApplyStyle()

    nameText = arrowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("BOTTOM", 0, 24)
    distText = arrowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    distText:SetPoint("BOTTOM", 0, 7)
    for _, fs in ipairs({ nameText, distText }) do
        if fs.GetFont and fs.SetFont then
            local font, size = fs:GetFont()
            if font then fs:SetFont(font, size, "OUTLINE") end
        end
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 1)
    end

    arrowFrame:SetScript("OnClick", function(_, button)
        if moveMode then return end
        if OMQ.Guide and OMQ.Guide:IsActive() then
            local back = IsShiftKeyDown and IsShiftKeyDown()
            if button == "LeftButton" then OMQ.Guide:Cycle(back and -1 or 1)
            else OMQ.Guide:Clear() end
            return
        end
        local back = IsShiftKeyDown and IsShiftKeyDown()
        if button == "LeftButton" then A:CycleTarget(back and -1 or 1) else A:HideForFiveMinutes() end
    end)
    arrowFrame:SetScript("OnDragStart", function(self) if moveMode then self:StartMoving() end end)
    arrowFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition() end)
    arrowFrame:SetScript("OnUpdate", function(_, elapsed) turnStep(elapsed) end)
    applyPosition()
    arrowFrame:Hide()
end

local function render()
    if not arrowFrame then return end
    if moveMode then
        arrowFrame:Show()
        nameText:SetText("Arrow"); nameText:SetTextColor(0.89, 0.71, 0.29)
        distText:SetText("drag to move")
        rotate(0)
        texture:SetVertexColor(1, 0.82, 0)
        return
    end
    local g = OMQ.Guide and OMQ.Guide:Current()
    if g then
        nameText:SetText(g.name)
        nameText:SetTextColor(0.55, 0.85, 1)
        if g.otherZone then
            distText:SetText("other continent")
            rotate(0)
            texture:SetVertexColor(0.6, 0.63, 0.68)
        else
            distText:SetText(string.format("%d yd", math.floor(g.distance + 0.5)))
            texture:SetVertexColor(0.45, 0.8, 1)
            if g.heading then point(g.heading) end
        end
        arrowFrame:Show()
        return
    end
    if GetTime() < hideUntil then arrowFrame:Hide(); return end
    local state = A:Evaluate()
    if not state.show then arrowFrame:Hide(); return end
    local target = state.target
    nameText:SetText(target.name or "?")
    nameText:SetTextColor(classColor(target.class))
    if state.otherZone then
        -- 0 and 1 are the two continents; any other world is a dungeon or another instance
        local inst = target.pos and target.pos.inst
        distText:SetText((inst == 0 or inst == 1) and "other continent" or "in a dungeon")
        rotate(0)
        texture:SetVertexColor(0.6, 0.63, 0.68)
    else
        distText:SetText(string.format("%d yd", math.floor(state.distance + 0.5)))
        -- yellow at the threshold, red at twice the threshold
        local t = math.min(math.max(state.ratio - 1, 0), 1)
        texture:SetVertexColor(1, 0.82 - 0.72 * t, 0.1 * (1 - t))
        if state.heading then point(state.heading) end
    end
    arrowFrame:Show()
end

function A:SetMoveMode(on)
    moveMode = on and true or false
    OMQ:Fire("MOVE_MODE", moveMode)
    if not moveMode and arrowFrame then savePosition() end
    render()
end

function A:ToggleMoveMode() self:SetMoveMode(not moveMode) end
function A:SetThreshold(n)
    OMQ.db.arrow.threshold = n
    wasShown = false          -- judge the new value fresh, without hysteresis
end
function A:IsMoveMode() return moveMode end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local lastX, lastY
local function calibrationSample()
    local pos = myPosition()
    if not pos or (IsFalling and IsFalling()) then lastX = nil; return end
    local facing = GetPlayerFacing and GetPlayerFacing()
    if lastX and type(facing) == "number" then
        local da, db = pos.a - lastX, pos.b - lastY
        local d = math.sqrt(da * da + db * db)
        if d >= 3 and d <= 14 then A.CalibrationVote(da, db, facing) end
    end
    lastX, lastY = pos.a, pos.b
end

OMQ:On("DB_READY", function()
    OMQ.db.arrow = OMQ.db.arrow or {}
    local c = OMQ.db.arrow.cal
    if c then cal = { s = c.s, k = c.k } end
end)

OMQ:On("READY", function()
    build()
    C_Timer.NewTicker(POS_INTERVAL, function() pcall(sendPosition) end)
    C_Timer.NewTicker(0.5, function() pcall(calibrationSample) end)
    C_Timer.NewTicker(0.05, function() pcall(render) end)
end)
OMQ:On("MINIMAP_SHIFT_CLICK", function() A:ToggleMoveMode() end)

OMQ:RegisterCommand("arrow", function(arg)
    local cmd, value = (arg or ""):match("^(%S*)%s*(.-)$")
    if cmd == "threshold" then
        local n = tonumber(value)
        if not n or n < 20 or n > MAX_THRESHOLD then
            OMQ:Print("threshold must be a number between 20 and " .. MAX_THRESHOLD .. " yards")
            return
        end
        OMQ.db.arrow.threshold = n
        wasShown = false          -- judge the new threshold fresh, without hysteresis
        OMQ:Print("arrow threshold set to " .. n .. " yards")
    elseif cmd == "on" or cmd == "off" then
        OMQ.db.arrow.enabled = (cmd == "on")
        OMQ:Print("straggler arrow " .. cmd)
    elseif cmd == "move" then
        A:ToggleMoveMode()
        OMQ:Print("move mode " .. (moveMode and "on" or "off"))
    elseif cmd == "reset" then
        OMQ.db.arrow.point = nil
        applyPosition()
        hideUntil = 0
        OMQ:Print("arrow position and hide timer reset")
    elseif cmd == "recalibrate" then
        cal = nil; OMQ.db.arrow.cal = nil
        for i = 1, #votes do votes[i] = 0 end
        OMQ:Print("recalibrating: run in a few different directions")
    else
        local h, learned = A.GetCalibration()
        local state = A:Evaluate()
        OMQ:Print(string.format("arrow: threshold %d yd, axes %s (s=%d k=%d), now: %s",
            OMQ.db.arrow.threshold or DEFAULT_THRESHOLD, learned and "learned" or "default guess",
            h.s, h.k, state.show and "showing" or ("hidden (" .. tostring(state.reason) .. ")")))
        print("  /omq arrow threshold <20-500> | move | reset | recalibrate")
    end
end, "distance arrow: threshold, move, reset, recalibrate")
