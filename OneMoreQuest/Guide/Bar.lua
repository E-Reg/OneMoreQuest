-- One More Quest: icon bar for guidance.
-- Only the meeting point button is always visible. Hovering it slides out the
-- other icons; every click folds the menu in again. One click starts the arrow
-- towards the nearest place of that kind; clicking the active icon cancels it.
-- The meeting point button sets a point for the whole group.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local SIZE, GAP, PAD = 28, 3, 4

local B = {}
OMQ.GuideBar = B

local frame, buttons = nil, {}
local moveMode = false
local expanded, suppressed = false, false
local MEET = { id = "meet", label = "Meeting point", icon = "Interface\\Icons\\INV_BannerPVP_02" }

-- The position is stored as the left edge and vertical centre of the collapsed
-- bar (relative to the bottom left of the screen). The bar always grows to the
-- right; only when it would leave the screen it grows to the left instead and
-- the icons are mirrored, so the meeting point icon stays on the screen edge.
-- While it is dragged the bar is not clamped to the screen: the meeting point
-- icon itself can reach the right edge, and on the drop the bar flips.
local anchorLeft, anchorY = nil, nil
local flipped = false

local function collapsedW() return PAD * 2 + SIZE end
local count = 1                        -- number of items (meeting point + kinds + professions)
local function fullW() return PAD * 2 + count * (SIZE + GAP) - GAP end
local function screenW() return (UIParent and UIParent.GetWidth and UIParent:GetWidth()) or 1920 end
local function screenH() return (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 1080 end

local function loadPosition()
    local p = OMQ.db.guide.point
    if p and p[1] == "LEFT" and p[2] == "BOTTOMLEFT" and tonumber(p[3]) and tonumber(p[4]) then
        anchorLeft, anchorY = p[3], p[4]
    else
        -- default layout (decision 190): on the left edge, a little below the middle
        anchorLeft, anchorY = 0, screenH() * 0.468
    end
end

local function savePosition()
    local left = frame:GetLeft()
    local right = frame:GetRight()
    local top, bottom = frame:GetTop(), frame:GetBottom()
    if not (left and right and top and bottom) then return end
    anchorLeft = flipped and (right - collapsedW()) or left
    anchorY = (top + bottom) / 2
    -- the meeting point icon always stays fully on the screen
    anchorLeft = math.max(0, math.min(anchorLeft, screenW() - collapsedW()))
    local half = (SIZE + PAD * 2) / 2
    anchorY = math.max(half, math.min(anchorY, screenH() - half))
    OMQ.db.guide.point = { "LEFT", "BOTTOMLEFT", anchorLeft, anchorY }
end

local function layout()
    local n = expanded and count or 1
    flipped = expanded and (anchorLeft + fullW() > screenW())
    frame:ClearAllPoints()
    if flipped then
        frame:SetPoint("RIGHT", UIParent, "BOTTOMLEFT", anchorLeft + collapsedW(), anchorY)
    else
        frame:SetPoint("LEFT", UIParent, "BOTTOMLEFT", anchorLeft, anchorY)
    end
    frame:SetSize(PAD * 2 + n * (SIZE + GAP) - GAP, SIZE + PAD * 2)
    for i, b in ipairs(buttons) do
        if i <= n then
            local slot = flipped and (n - i) or (i - 1)
            b:ClearAllPoints()
            b:SetPoint("LEFT", frame, "LEFT", PAD + slot * (SIZE + GAP), 0)
            b:Show()
        else
            b:Hide()
        end
    end
    if B.onLayout then B.onLayout(frame, flipped) end      -- the check bar hangs above this bar
end

local function applyPosition()
    loadPosition()
    layout()
end

local function mouseOver()
    if frame.IsMouseOver then
        local ok, v = pcall(frame.IsMouseOver, frame)
        if ok then return v and true or false end
    end
    return MouseIsOver and MouseIsOver(frame) and true or false
end

function B:Refresh()
    if not frame then return end
    local active = OMQ.Guide:Kind()
    for _, b in ipairs(buttons) do
        if b.kind == active then b.mark:Show() else b.mark:Hide() end
    end
    if (OMQ.db.guide.bar and OMQ:Master("guidance")) or moveMode then frame:Show() else frame:Hide() end
    layout()
end

local function setExpanded(on)
    expanded = on and true or false
    if expanded and B.Rebuild and B.ProfessionsChanged and B:ProfessionsChanged() then B:Rebuild() end
    layout()
end

local function onUpdate(_, elapsed)
    B.t = (B.t or 0) + (elapsed or 0)
    if B.t < 0.05 then return end
    B.t = 0
    local over = mouseOver()
    if not over then suppressed = false end
    local want = moveMode or B.tourOpen or (over and not suppressed)     -- tourOpen: the guided tour (decision 244)
    if want ~= expanded then setExpanded(want) end
end

local function click(k)
    if moveMode then return end
    if k.id == "meet" then
        OMQ.Guide:SetMeetingPoint()
    elseif OMQ.Guide:Kind() == k.id then
        OMQ.Guide:Clear()
    else
        OMQ.Guide:Start(k.id)
    end
    suppressed = true
    setExpanded(false)
end

local startDrag, stopDrag

local function makeButton()
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(SIZE, SIZE)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.mark = b:CreateTexture(nil, "OVERLAY")
    b.mark:SetPoint("TOPLEFT", -2, 2); b.mark:SetPoint("BOTTOMRIGHT", 2, -2)
    b.mark:SetColorTexture(0.45, 0.8, 1, 0.45)
    b.mark:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function() startDrag() end)
    b:SetScript("OnDragStop", function() stopDrag() end)
    b:SetScript("OnClick", function(self) click(self.item) end)
    b:SetScript("OnEnter", function(self)
        local k = self.item
        if not (GameTooltip and k) then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(k.label)
        if k.id == "meet" then
            GameTooltip:AddLine("Click: arrow to here for the whole group", 0.8, 0.8, 0.8)
        else
            GameTooltip:AddLine(OMQ.Guide:Kind() == k.id and "Click: cancel" or "Click: show the way", 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return b
end

-- (Re)builds the item list: meeting point, the fixed kinds and one trainer
-- button for every profession the player has.
local profSignature = ""
local function professionItems()
    local out = {}
    local lines = OMQ.Alerts and OMQ.Alerts.ProfessionLines and OMQ.Alerts.ProfessionLines()
    for _, l in ipairs(lines or {}) do
        local icon = l.key and OMQ.Guide.profIcons[l.key]
        if icon then
            out[#out + 1] = { id = "proftrainer:" .. l.key, label = l.name .. " trainer", icon = icon }
        end
    end
    table.sort(out, function(x, y) return x.label < y.label end)
    return out
end

function B:Rebuild()
    if not frame then return end
    local items = { MEET }
    for _, k in ipairs(OMQ.Guide.kinds) do items[#items + 1] = k end
    local profs = professionItems()
    local sig = {}
    for _, k in ipairs(profs) do items[#items + 1] = k; sig[#sig + 1] = k.id end
    profSignature = table.concat(sig, ",")
    for i, k in ipairs(items) do
        local b = buttons[i]
        if not b then b = makeButton(); buttons[i] = b end
        b.item, b.kind = k, k.id
        b.icon:SetTexture(k.icon)
    end
    for i = #items + 1, #buttons do buttons[i].item = nil; buttons[i].kind = nil end
    count = #items
    self:Refresh()
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestGuideBar", UIParent)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    startDrag = function()
        if not moveMode then return end
        frame:SetClampedToScreen(false)          -- lets the meeting point icon reach the right edge
        frame:StartMoving()
    end
    stopDrag = function()
        frame:StopMovingOrSizing()
        savePosition()
        frame:SetClampedToScreen(true)
        layout()
    end
    frame:SetScript("OnDragStart", startDrag)
    frame:SetScript("OnDragStop", stopDrag)

    local plate = frame:CreateTexture(nil, "BACKGROUND")
    plate:SetAllPoints()
    plate:SetColorTexture(0.07, 0.08, 0.105, 0.92)

    frame:SetScript("OnUpdate", onUpdate)
    applyPosition()
    B:Rebuild()
end

function B:SetShown(on)
    OMQ.db.guide.bar = on and true or false
    self:Refresh()
end

function B:IsExpanded() return expanded end
function B:Frame() return frame end
function B:IsFlipped() return flipped end
function B:AnchorLeft() return anchorLeft end       -- left edge of the meeting point icon area
function B:AnchorButton() return buttons[1] end     -- the meeting point button (always shown)
function B:Count() return count end
function B:ItemId(i) return buttons[i] and buttons[i].kind end

function B:ProfessionsChanged()
    local sig = {}
    for _, k in ipairs(professionItems()) do sig[#sig + 1] = k.id end
    return table.concat(sig, ",") ~= profSignature
end

OMQ:On("READY", function() build() end)
do
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("SKILL_LINES_CHANGED")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", function()
        if frame and B:ProfessionsChanged() then B:Rebuild() end
    end)
end
OMQ:On("GUIDE_CHANGED", function() B:Refresh() end)
OMQ:On("MOVE_MODE", function(on) moveMode = on and true or false; B:Refresh() end)

OMQ:RegisterCommand("bar", function(arg)
    if arg == "reset" then
        OMQ.db.guide.point = nil
        if frame then applyPosition() end
        OMQ:Print("guide bar position reset")
        return
    end
    B:SetShown(not OMQ.db.guide.bar)
    OMQ:Print("guide bar " .. (OMQ.db.guide.bar and "shown" or "hidden"))
end, "toggle the guidance bar (/omq bar reset: reset position)")
