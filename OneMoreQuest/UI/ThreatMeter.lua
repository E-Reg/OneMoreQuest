-- One More Quest: the threat meter (decision 333, step 2)
-- A small frame that shows, for the current target, how much threat the player, the pet, the party and their
-- pets have, as the game's scaled percentage (UnitDetailedThreatSituation, 100 = the unit is the target; it can
-- be above 100 for a moment before the mob turns). Shown in a group, in dungeons or never (option), always inside a dungeon, 8 seconds after a fight, whenever
-- somebody has threat on the target, also when I have none yet. Values the game
-- does not give (secret) are skipped; when nothing is readable the frame stays hidden. In combat without
-- an attackable target a faded one line hint shows. It can be dragged in the move mode only; /omq threat reset puts it back.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local M = {}
OMQ.ThreatMeter = M

M.MAX_ROWS = 8
M.WARM = 70                 -- from here a bar turns warm
M.HOT = 90                  -- from here my own bar turns red: the next hit may pull
local ROW_H, GAP, WIDTH = 18, 3, 210
local GOLD = { 0.89, 0.71, 0.29 }
local COLOR = {
    tank = { 0.64, 0.50, 0.21 }, warm = { 0.89, 0.71, 0.29 }, calm = { 0.39, 0.44, 0.55 }, hot = { 0.84, 0.33, 0.20 },
}
local PET_COLOR = { 0.56, 0.69, 0.38 }
local function isSecret(v) return issecretvalue and issecretvalue(v) or false end
COLOR.good = { 0.26, 0.66, 0.32 }          -- tank mode: I hold the aggro

-- Tank mode (decisions 337, 338): on when I have the role Tank in the group (the role assigned in the group
-- finder or by the leader), or the main tank mark of a raid. The role is read from the game.
function M.MyGroupRole()
    local role, mt
    if UnitGroupRolesAssigned then
        local ok, r = pcall(UnitGroupRolesAssigned, "player")
        if ok and type(r) == "string" and not isSecret(r) then role = r end
    end
    if GetPartyAssignment then
        local ok, v = pcall(GetPartyAssignment, "MAINTANK", "player")
        if ok and not isSecret(v) and v then mt = true end
    end
    return role, mt
end

function M.TankMode()
    local role, mt = M.MyGroupRole()
    return role == "TANK" or mt == true
end

local function inGroup() return (IsInGroup and IsInGroup()) and true or false end

-- when the meter may show (decision 335): "group" = in a group, "dungeon" = inside a dungeon or raid, "never"
function M.Mode()
    local o = OMQ.db and OMQ.db.options
    local m = o and o.threatMode
    if m == "group" or m == "dungeon" or m == "never" then return m end
    if o and o.threat == false then return "never" end         -- the old on/off option (0.54.24)
    return "group"
end

local function inDungeon()
    if not IsInInstance then return false end
    local inside, kind = IsInInstance()
    return inside and (kind == "party" or kind == "raid") or false
end

local function modeAllows()
    if OMQ.Unlock and not OMQ.Unlock:Has("threat") then return false end   -- off until the first dungeon
    local m = M.Mode()
    if m == "never" then return false end
    if m == "dungeon" then return inDungeon() end
    return inGroup()
end


local function classColor(unit)
    local ok, _, file = pcall(UnitClass, unit)
    local c = ok and file and not isSecret(file) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
    if c then return { c.r, c.g, c.b } end
    return { 0.8, 0.8, 0.8 }
end

-- what to show: state "hidden" | "notarget" | "rows"; rows sorted, highest first
M.GRACE = 8                 -- seconds the frame stays after a fight (decision 336)
M.graceUntil = 0
M.hintText = ""
local function graceActive() return GetTime and GetTime() < M.graceUntil end

-- nothing to list: a faded hint line or nothing. The hint shows while I fight, always inside a dungeon
-- and for the grace period after a fight (decision 336)
local function quiet(fighting, targetOk)
    local text
    if fighting then text = targetOk and "No threat" or "No target in combat"
    elseif inDungeon() then text = targetOk and "No threat" or "No target"
    elseif graceActive() then text = "Combat over" end
    if text then M.hintText = text; return "notarget" end
    return "hidden"
end

function M.Compute()
    if not modeAllows() then return "hidden" end
    local fighting = UnitAffectingCombat and UnitAffectingCombat("player") and true or false
    -- the rows show whenever somebody has threat on the target, also when I have none yet (decision 335)
    local T = OMQ.ThreatProbe
    if not (T and UnitExists and UnitExists("target")) then return quiet(fighting, false) end
    local okA, attack = pcall(UnitCanAttack, "player", "target")
    if not okA or attack ~= true then return quiet(fighting, false) end
    if UnitIsDead and UnitIsDead("target") then return quiet(fighting, false) end
    local rows = {}
    local tankMode = M.TankMode()
    local sawSecret = false
    for _, unit in ipairs(T.UNITS) do
        local r = T.Read(unit, "target")
        if r and isSecret(r.scaled) then sawSecret = true end
        if r and not r.err and not r.none and type(r.scaled) == "number" and not isSecret(r.scaled) and r.scaled > 0 then
            local pet = unit == "pet" or unit:find("^partypet") ~= nil
            rows[#rows + 1] = {
                unit = unit, name = tostring(r.name), pct = r.scaled, pet = pet,
                tank = (not isSecret(r.tank)) and r.tank == true, me = unit == "player",
                color = pet and PET_COLOR or classColor(unit), tankMode = tankMode,
            }
        end
    end
    if #rows == 0 then
        -- values the game hides: nothing to show (a dungeon keeps its frame); a target without threat in
        -- my fight: the hint, the frame stays (decision 339)
        if sawSecret then return inDungeon() and quiet(false, true) or "hidden" end
        return quiet(fighting, true)
    end
    local mine = false
    for _, r in ipairs(rows) do if r.me then mine = true end end
    if not mine then
        -- somebody has threat and I have none yet: my own row at 0
        local okN, nm = pcall(UnitName, "player")
        rows[#rows + 1] = { unit = "player", name = okN and nm and not isSecret(nm) and tostring(nm) or "?", pct = 0,
                            pet = false, tank = false, me = true, color = classColor("player") }
    end
    table.sort(rows, function(a, b) if a.pct ~= b.pct then return a.pct > b.pct end return a.unit < b.unit end)
    while #rows > M.MAX_ROWS do table.remove(rows) end
    return "rows", rows
end

-- the bar colour of a row
function M.BarColor(row)
    if row.tankMode then
        -- tank mode: somebody else holds the aggro = red, I hold it = green, the rest as usual
        if row.tank then return row.me and COLOR.good or COLOR.hot end
        if row.pct >= M.WARM then return COLOR.warm end
        return COLOR.calm
    end
    if row.tank then return COLOR.tank end
    if row.me and row.pct >= M.HOT then return COLOR.hot end
    if row.pct >= M.WARM then return COLOR.warm end
    return COLOR.calm
end

----------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------
local frame, head, tag, targetText, hint
local pool = {}

local function getRow(i)
    if pool[i] then return pool[i] end
    local row = CreateFrame("Frame", nil, frame)
    row:SetHeight(ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0.114, 0.129, 0.169, 1)
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetPoint("TOPLEFT")
    row.bar:SetPoint("BOTTOMLEFT")
    row.edge = row:CreateTexture(nil, "OVERLAY")
    row.edge:SetPoint("TOPLEFT")
    row.edge:SetPoint("BOTTOMLEFT")
    row.edge:SetWidth(2)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", 6, 0)
    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.value:SetPoint("RIGHT", -6, 0)
    row.name:SetPoint("RIGHT", row.value, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")
    pool[i] = row
    return row
end

M.DEFAULT_POS = { "TOPLEFT", "TOPLEFT", 120, -300 }
function M.ApplyPosition()
    if not frame then return end
    local p = OMQ.db and OMQ.db.threatPos
    if not (p and p[1] == "TOPLEFT") then p = M.DEFAULT_POS end      -- an older centred position is dropped
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", p[3], p[4])
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestThreat", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetWidth(WIDTH)
    frame:EnableMouse(M.moveMode and true or false)
    M.ApplyPosition()
    frame:SetScript("OnDragStart", function() if M.moveMode then frame:StartMoving() end end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        -- saved by the top left corner: the top edge stays, the frame grows downward (decision 335)
        local left, top = frame:GetLeft(), frame:GetTop()
        local pl, pt = UIParent:GetLeft() or 0, UIParent:GetTop() or 0
        OMQ.db.threatPos = { "TOPLEFT", "TOPLEFT", (left or 0) - pl, (top or 0) - pt }
        M.ApplyPosition()
    end)
    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.64, 0.50, 0.21, 1)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.078, 0.09, 0.122, 0.94)
    tag = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tag:SetPoint("TOPLEFT", 8, -7)
    tag:SetText("THREAT")
    tag:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    targetText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetText:SetPoint("TOPRIGHT", -8, -7)
    targetText:SetPoint("LEFT", tag, "RIGHT", 8, 0)
    targetText:SetJustifyH("RIGHT")
    hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", tag, "RIGHT", 8, 0)
    hint:SetTextColor(0.55, 0.58, 0.63)
    hint:SetText("No target in combat")
    frame:Hide()
end

local function targetName()
    local ok, n = pcall(UnitName, "target")
    if ok and n and not isSecret(n) then return tostring(n) end
    return ""
end

local function render(rows, name)
    frame:SetAlpha(1)
    hint:Hide()
    targetText:SetText(name or "")
    local top = -24
    for i, r in ipairs(rows) do
        local row = getRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, top)
        row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, top)
        local c = M.BarColor(r)
        row.bar:SetColorTexture(c[1], c[2], c[3], r.tank and 0.75 or 0.55)
        row.bar:SetWidth(math.max(1, (WIDTH - 12) * math.min(r.pct, 100) / 100))
        if r.tankMode and r.tank then
            if r.me then row.edge:SetColorTexture(0.45, 0.9, 0.5, 1) else row.edge:SetColorTexture(1, 0.54, 0.36, 1) end
        elseif r.tankMode then
            row.edge:SetColorTexture(0, 0, 0, 0)
        elseif r.tank then
            row.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        elseif r.me and r.pct >= M.HOT then
            row.edge:SetColorTexture(1, 0.54, 0.36, 1)
        else
            row.edge:SetColorTexture(0, 0, 0, 0)
        end
        row.name:SetText(r.pet and (r.name .. " (pet)") or r.name)
        row.name:SetTextColor(r.color[1], r.color[2], r.color[3])
        row.value:SetText(string.format("%d", math.floor(r.pct + 0.5)))
        row:Show()
        top = top - ROW_H - GAP
    end
    for i = #rows + 1, #pool do pool[i]:Hide() end
    frame:SetHeight(-top + 5)
end

-- three sample rows while the move mode is on, so the frame can be seen and placed
local DEMO = {
    { name = "Tank", pct = 100, tank = true, me = false, pet = false, color = { 0.78, 0.61, 0.43 } },
    { name = "You", pct = 74, tank = false, me = true, pet = false, color = { 1, 1, 1 } },
    { name = "Pet", pct = 22, tank = false, me = false, pet = true, color = PET_COLOR },
}

function M.Refresh()
    if M.moveMode then
        if not frame then build() end
        frame:EnableMouse(true)
        frame:Show()
        render(DEMO, "Move mode: drag me")
        return "move"
    end
    local state, rows = M.Compute()
    M.visible = state ~= "hidden"
    if state == "hidden" then
        if frame then frame:Hide() end
        return state
    end
    if not frame then build() end
    frame:EnableMouse(false)
    frame:Show()
    if state == "notarget" then
        frame:SetAlpha(0.55)
        targetText:SetText("")
        hint:SetText(M.hintText)
        hint:Show()
        frame:SetHeight(26)
        for _, row in ipairs(pool) do row:Hide() end
        return state
    end
    render(rows, targetName())
    return state
end

function M.ResetPosition()
    if OMQ.db then OMQ.db.threatPos = nil end
    M.ApplyPosition()
end

OMQ:On("MOVE_MODE", function(on)
    M.moveMode = on and true or false
    M.Refresh()
end)

local driver = CreateFrame("Frame")
local acc = 0
for _, e in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "UNIT_THREAT_LIST_UPDATE" }) do
    pcall(driver.RegisterEvent, driver, e)
end
driver:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and M.visible and GetTime then M.graceUntil = GetTime() + M.GRACE end
    if event == "PLAYER_REGEN_DISABLED" then M.graceUntil = 0 end
    M.Refresh()
end)
driver:SetScript("OnUpdate", function(_, dt)
    acc = acc + (dt or 0)
    if acc < 0.4 then return end
    acc = 0
    M.Refresh()
end)
