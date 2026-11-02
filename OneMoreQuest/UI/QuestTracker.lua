-- One More Quest: group quest tracker, the card on screen (section 21, mockup on the canvas
-- "One More Quest – Group Quest Tracker"). Plain frame without protected calls, so it works in combat.
-- Right click closes it until the next progress; the mouse over it keeps it open (decisions 157, 158).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local W, PAD, LABEL_MIN, COL_W, ROW_H, GAP = 380, 12, 120, 56, 26, 4
local GOLD = { 0.89, 0.71, 0.29 }
local TAN = { 0.72, 0.63, 0.42 }
local GREEN = { 0.49, 0.78, 0.44 }
local STAMP_SIZE = 190

local U = {}
OMQ.QTrackFrame = U

local frame, header, title, level, prevBtn, navText, nextBtn, stampFrame, stampTex, stampAnim, dim
local texts, texs, tUsed, xUsed = {}, {}, 0, 0
local moveMode = false
local lastStamp

local function classColor(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- background of the card (decision 207): "none" (default, the text gets a shadow so it reads on
-- the game world), "light" (more see-through) or "full" (the old dark card)
U.BACKGROUNDS = { "none", "light", "full" }
U.BG_LABEL = { none = "None", light = "Light", full = "Full" }
local bgTex, borderTex
function U:Background()
    local v = OMQ.db and OMQ.db.options and OMQ.db.options.qtrackBg
    for _, b in ipairs(U.BACKGROUNDS) do if b == v then return v end end
    return "none"
end
local function shade(fs)
    if not fs then return end
    if U:Background() == "full" then
        if fs.SetShadowOffset then fs:SetShadowOffset(1, -1) end
        if fs.SetShadowColor then fs:SetShadowColor(0, 0, 0, 0.6) end
    else
        if fs.SetShadowOffset then fs:SetShadowOffset(1.5, -1.5) end
        if fs.SetShadowColor then fs:SetShadowColor(0, 0, 0, 1) end
    end
end
U._shade = shade
function U:_BgTextures() return bgTex, borderTex end
local function applyBackground()
    if not bgTex then return end
    local b = U:Background()
    if b == "none" then
        bgTex:Hide(); borderTex:Hide()
    elseif b == "light" then
        bgTex:Show(); borderTex:Show()
        bgTex:SetColorTexture(0.08, 0.086, 0.114, 0.45)
        borderTex:SetColorTexture(0.23, 0.2, 0.13, 0.45)
    else
        bgTex:Show(); borderTex:Show()
        bgTex:SetColorTexture(0.08, 0.086, 0.114, 0.97)
        borderTex:SetColorTexture(0.23, 0.2, 0.13, 1)
    end
    if dim then dim:SetAlpha(b == "none" and 0 or (b == "light" and 0.5 or 1)) end
    for _, fs in ipairs({ header, title, level, navText }) do shade(fs) end
    for _, fs in ipairs(texts) do shade(fs) end
end
function U:SetBackground(b)
    OMQ.db.options.qtrackBg = b
    applyBackground()
end
function U:CycleBackground()
    local cur = self:Background()
    for i, b in ipairs(U.BACKGROUNDS) do
        if b == cur then self:SetBackground(U.BACKGROUNDS[i % #U.BACKGROUNDS + 1]); return end
    end
end

local function newText(font)
    tUsed = tUsed + 1
    local fs = texts[tUsed]
    if not fs then fs = frame:CreateFontString(nil, "OVERLAY", font); texts[tUsed] = fs end
    fs:SetFontObject(font)
    shade(fs)
    fs:ClearAllPoints()
    fs:Show()
    return fs
end

local function newTex()
    xUsed = xUsed + 1
    local t = texs[xUsed]
    if not t then t = frame:CreateTexture(nil, "BACKGROUND", nil, 1); texs[xUsed] = t end
    t:ClearAllPoints()
    t:Show()
    return t
end

----------------------------------------------------------------------
-- Position (move mode like the arrow and the alerts)
----------------------------------------------------------------------
local DEFAULT_POINT = { "LEFT", "LEFT", 0, 165 }        -- default layout (decision 190)

local function store()
    OMQ.db.qtrack = OMQ.db.qtrack or {}
    return OMQ.db.qtrack
end

local function applyPosition()
    local p = store().point or DEFAULT_POINT
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

local function savePosition()
    local point, _, rel, x, y = frame:GetPoint()
    if point then store().point = { point, rel or point, x or 0, y or 0 } end
end

function U:ResetPosition()
    store().point = nil
    if frame then applyPosition() end
end

----------------------------------------------------------------------
-- Building
----------------------------------------------------------------------
local function navButton(dir)
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(22, 22)
    local up = dir < 0 and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up"
    local down = dir < 0 and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down"
    b:SetNormalTexture(up)
    b:SetPushedTexture(down)
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function() OMQ.QTrack:Next(dir) end)
    return b
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestQuestTracker", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if moveMode then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition() end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and not moveMode then OMQ.QTrack:Close() end
    end)
    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
    borderTex = border
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.23, 0.2, 0.13, 1)
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgTex = bg
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.086, 0.114, 0.97)
    local edge = frame:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT"); edge:SetHeight(3)
    edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)

    header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", PAD, -10)
    header:SetText("GROUP QUEST")
    header:SetTextColor(TAN[1], TAN[2], TAN[3])
    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD, -24)
    title:SetJustifyH("LEFT")
    if title.SetWordWrap then title:SetWordWrap(false) end
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    level = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    level:SetPoint("LEFT", title, "RIGHT", 6, 0)
    level:SetTextColor(0.66, 0.69, 0.73)

    nextBtn = navButton(1)
    nextBtn:SetPoint("TOPRIGHT", -8, -14)
    navText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    navText:SetPoint("RIGHT", nextBtn, "LEFT", -2, 0)
    navText:SetTextColor(0.66, 0.69, 0.73)
    prevBtn = navButton(-1)
    prevBtn:SetPoint("RIGHT", navText, "LEFT", -2, 0)
    applyBackground()

    -- the stamp sits above everything on its own frame
    stampFrame = CreateFrame("Frame", nil, frame)
    stampFrame:SetAllPoints()
    stampFrame:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)
    dim = stampFrame:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetColorTexture(0.047, 0.05, 0.07, 0.45)
    applyBackground()
    stampTex = stampFrame:CreateTexture(nil, "OVERLAY")
    stampTex:SetSize(STAMP_SIZE, STAMP_SIZE)
    stampTex:SetPoint("CENTER")
    -- lands like a rubber stamp: from 1.6 times the size down to its size in 0.15 s
    pcall(function()
        stampAnim = stampTex:CreateAnimationGroup()
        local s = stampAnim:CreateAnimation("Scale")
        if s.SetScaleFrom then s:SetScaleFrom(1.6, 1.6); s:SetScaleTo(1, 1)
        else s:SetFromScale(1.6, 1.6); s:SetToScale(1, 1) end
        s:SetDuration(0.15)
        local a = stampAnim:CreateAnimation("Alpha")
        a:SetFromAlpha(0); a:SetToAlpha(1); a:SetDuration(0.1)
    end)
    stampFrame:Hide()

    -- the mouse over the card keeps it open (polled, so the buttons on it do not break it)
    local acc = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        local over = false
        if self.IsMouseOver then local ok, v = pcall(self.IsMouseOver, self); over = ok and v and true or false end
        if not over and OMQ.QuestItem and OMQ.QuestItem:IsMouseOver() then over = true end   -- its item button (354)
        OMQ.QTrack:SetHover(over)
        acc = acc + (elapsed or 0)
        if acc >= 0.25 then acc = 0; U:Render() end          -- the light on a changed cell fades
    end)
    applyPosition()
    frame:Hide()
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------
local DEMO = {
    title = "Quest Tracker", level = nil, showNav = false, stamp = false,
    cols = {}, rows = { { text = "Move mode: drag me to a new position", cells = {} } },
}

function U:Render()
    if not frame then return end
    local Q = OMQ.QTrack
    local view = moveMode and DEMO or (Q:Shown() and Q:View())
    if not view then
        frame:Hide()
        lastStamp = nil
        Q:SetHover(false)                -- a hidden card cannot hold the mouse
        return
    end
    tUsed, xUsed = 0, 0
    for _, fs in ipairs(texts) do fs:Hide() end
    for _, t in ipairs(texs) do t:Hide() end

    title:SetText(view.title or "")
    level:SetText(view.level and ("[" .. view.level .. "]") or "")
    local cols = moveMode and {} or view.cols
    local ncols = #cols
    local labelW = W - PAD * 2 - ncols * (COL_W + GAP)
    if labelW < LABEL_MIN then labelW = LABEL_MIN end
    local width = PAD * 2 + labelW + ncols * (COL_W + GAP)
    -- the quest level right behind the name, not at the far right where the arrows of several
    -- cards cover it (decision 206): the name gets only as wide as it is, at most the room left
    local room = width - PAD * 2 - (view.showNav and 90 or 30)
    local function textW(fs)
        local v = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()
        if type(v) ~= "number" then v = fs:GetStringWidth() end
        return type(v) == "number" and v or nil
    end
    local levelW = view.level and ((textW(level) or 24) + 6) or 0
    local nameW = textW(title) or room
    title:SetWidth(math.max(20, math.min(nameW + 2, room - levelW)))
    if view.showNav then
        navText:SetText(view.nav); navText:Show(); prevBtn:Show(); nextBtn:Show()
    else
        navText:Hide(); prevBtn:Hide(); nextBtn:Hide()
    end

    local y = -46
    -- column heads: the dads in class colours
    for j, c in ipairs(cols) do
        local fs = newText("GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + labelW + GAP + (j - 1) * (COL_W + GAP), y)
        fs:SetWidth(COL_W)
        fs:SetJustifyH("CENTER")
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        fs:SetText(c.name or "?")
        fs:SetTextColor(classColor(c.class))
    end
    if ncols > 0 then y = y - 16 end
    for _, r in ipairs(view.rows) do
        local label = newText("GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y - 6)
        label:SetWidth(labelW)
        label:SetJustifyH("LEFT")
        if label.SetWordWrap then label:SetWordWrap(false) end
        label:SetText(r.text or "")
        -- on a see-through card the objective is pure white, like the names (decision 210)
        if U:Background() == "full" then label:SetTextColor(0.79, 0.8, 0.84) else label:SetTextColor(1, 1, 1) end
        for j, cell in ipairs(r.cells) do
            local x = PAD + labelW + GAP + (j - 1) * (COL_W + GAP)
            local box = newTex()
            box:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
            box:SetSize(COL_W, ROW_H - 2)
            if cell.lit then box:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.32)
            elseif cell.isSelf then box:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.10)
            else box:SetColorTexture(1, 1, 1, 0.04) end
            local fs = newText("GameFontHighlightSmall")
            fs:SetPoint("CENTER", frame, "TOPLEFT", x + COL_W / 2, y - (ROW_H - 2) / 2)
            fs:SetText(cell.text or "")
            if cell.state == "done" then fs:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
            elseif cell.state == "none" or cell.state == "wait" then fs:SetTextColor(0.36, 0.38, 0.42)
            else fs:SetTextColor(0.93, 0.92, 0.89) end
        end
        y = y - ROW_H
    end
    frame:SetSize(width, -y + 10)

    if view.stamp then
        stampFrame:Show()
        if lastStamp ~= view.qid then
            lastStamp = view.qid
            local k = view.stampKind or OMQ.QTrack.STAMPS[1]          -- the same stamp for every dad (decision 160)
            stampTex:SetTexture(k.file)
            stampTex:SetVertexColor(k.color[1], k.color[2], k.color[3], 1)
            U.stampKey = k.key
            if stampAnim then pcall(stampAnim.Play, stampAnim) end
        end
    else
        stampFrame:Hide()
        lastStamp = nil
    end
    frame:Show()
end

function U:IsShown() return frame and frame:IsShown() or false end
function U:Frame() return frame end

OMQ:On("READY", function() build(); U:Render() end)
OMQ:On("QTRACK_CHANGED", function() U:Render() end)
OMQ:On("SETTINGS_CHANGED", function() U:Render() end)
OMQ:On("MOVE_MODE", function(on)
    moveMode = on and true or false
    if not frame then return end
    if not moveMode then savePosition() end
    U:Render()
end)
