-- One More Quest: minimap icon
-- Left click: lifetime window (the vote window while a vote waits for me), right click: quick options, shift + right click: full options,
-- shift + drag: move around the minimap, shift + left click: move mode (decision 79),
-- ctrl + left click: end this session and start a new one (decision 328).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local RADIUS_OFFSET = 5
local button

----------------------------------------------------------------------
-- State of the addon, shown on the icon and in the tooltip (decision 115)
--   paused   alerts snoozed or switched off: grey icon with a "z"
--   voting   a vote runs and I have not voted: the icon pulses
--   differs  group members run another version: small amber dot
----------------------------------------------------------------------
local M = {}
OMQ.Minimap = M

function M:State()
    local st = { paused = false, voting = false, differs = {}, dads = 0 }
    local A = OMQ.Alerts
    if A and A.IsSnoozed and A:IsSnoozed() then
        st.paused = true
        local left = math.max(1, math.ceil(((OMQ.db.options.snoozeUntil or 0) - time()) / 60))
        st.pausedText = "Alerts snoozed (" .. left .. " min)"
    elseif OMQ.Master and not OMQ:Master("alerts") then
        st.paused = true
        st.pausedText = "Alerts are switched off"
    end
    st.voting = OMQ.Vote and OMQ.Vote.NeedsMyVote and OMQ.Vote:NeedsMyVote() or false
    local me = OMQ:GetSelf()
    local names = {}
    st.versions = {}
    for guid, u in pairs(OMQ.users or {}) do
        if OMQ:IsOnline(u) and not (me and guid == me.guid) then
            st.dads = st.dads + 1
            if u.version and u.version ~= "" and u.version ~= OMQ.version then
                names[#names + 1] = (u.name or "?") .. " " .. u.version
                local newer, older = OMQ.VersionNewer(u.version, OMQ.version), OMQ.VersionNewer(OMQ.version, u.version)
                if newer or older then
                    st.versions[#st.versions + 1] = { name = u.name or "?", version = u.version, newer = newer }
                end
            end
        end
    end
    table.sort(names)
    table.sort(st.versions, function(a, b) return a.name < b.name end)
    st.differs = names
    return st
end

-- "0.36.0" newer than "0.35.2"? Parts compared as numbers; a suffix like "-sim" is ignored
function OMQ.VersionNewer(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local x, y = parts(a), parts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

local function updatePosition()
    local angle = math.rad(OMQ.db.minimap.angle or 200)
    local w = (Minimap:GetWidth() / 2) + RADIUS_OFFSET
    local h = (Minimap:GetHeight() / 2) + RADIUS_OFFSET
    local x, y = math.cos(angle) * w, math.sin(angle) * h
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onDragUpdate()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    OMQ.db.minimap.angle = angle
    updatePosition()
end

local function createButton()
    button = CreateFrame("Button", "OneMoreQuestMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    -- Solid dark disc behind the icon, so the content is never see-through
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(22, 22)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetVertexColor(0.08, 0.09, 0.12, 1)
    bg:SetPoint("CENTER", 0, 0)
    button.bg = bg

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    icon:SetPoint("CENTER", 0, 0)
    button.icon = icon

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- vote glow (behind the icon), "z" for paused, dot for another version
    local glow = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    glow:SetSize(30, 30)
    glow:SetPoint("CENTER", 0, 0)
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(0.89, 0.71, 0.29)
    glow:SetAlpha(0)
    button.glow = glow
    local z = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    z:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 5)
    z:SetText("z")
    z:SetTextColor(0.75, 0.78, 0.84)
    z:Hide()
    button.z = z
    local dot = button:CreateTexture(nil, "OVERLAY", nil, 2)
    dot:SetSize(10, 10)
    dot:SetPoint("TOPRIGHT", button, "TOPRIGHT", -3, -3)
    dot:SetTexture("Interface\\COMMON\\Indicator-Yellow")
    dot:Hide()
    button.dot = dot
    local elapsed, pulse = 0, false
    -- own frame: dragging replaces the OnUpdate of the button itself
    local ticker = CreateFrame("Frame", nil, button)
    ticker:SetScript("OnUpdate", function(_, dt)
        if pulse then
            button.glow:SetAlpha(0.35 + 0.35 * math.sin(GetTime() * 5))
        end
        elapsed = elapsed + dt
        if elapsed < 0.5 then return end
        elapsed = 0
        M:Apply()
        pulse = M.pulsing
    end)

    button:SetScript("OnEnter", function(self) OMQ.Tooltip:Show(self) end)
    button:SetScript("OnLeave", function() OMQ.Tooltip:Hide() end)
    -- a tooltip taller than the room below the icon scrolls with the wheel (decision 376)
    if button.EnableMouseWheel then button:EnableMouseWheel(true) end
    button:SetScript("OnMouseWheel", function(self, delta)
        if OMQ.Tooltip:IsShownFor(self) then OMQ.Tooltip:Scroll(delta) end
    end)
    button:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self:SetScript("OnUpdate", onDragUpdate)
        end
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnClick", function(_, mouse)
        -- any click closes the hover tooltip; the next hover opens it again
        OMQ.Tooltip:Hide()
        if mouse == "RightButton" and IsShiftKeyDown() then
            OMQ:Fire("MINIMAP_SHIFT_RIGHT_CLICK")
        elseif mouse == "LeftButton" and IsShiftKeyDown() then
            OMQ:Fire("MINIMAP_SHIFT_CLICK")
        elseif mouse == "LeftButton" and IsControlKeyDown and IsControlKeyDown() then
            -- ctrl + left click: this session ends and a new one starts (decision 328)
            if OMQ.Measure and OMQ.Measure.ResetSession then
                OMQ.Measure:ResetSession()
                OMQ:Print("new session started")
            end
        elseif mouse == "LeftButton" then
            -- while the icon pulses (a vote waits for me) the click opens the vote window
            if OMQ.Vote and OMQ.Vote:NeedsMyVote() and OMQ.Vote:ShowWindow() then return end
            OMQ:Fire("MINIMAP_LEFT_CLICK")
        else
            OMQ:Fire("MINIMAP_RIGHT_CLICK")
        end
    end)

    updatePosition()
    if OMQ.db.minimap.hidden then button:Hide() end
end

OMQ:On("READY", createButton)

function M:Apply()
    if not button then return end
    local st = self:State()
    self.last = st
    self.pulsing = st.voting
    button.icon:SetDesaturated(st.paused)
    if st.paused then button.icon:SetVertexColor(0.7, 0.72, 0.78) else button.icon:SetVertexColor(1, 1, 1) end
    -- dimmed while showing cards rests after a counter (UI/Ledger.lua)
    local resting = OMQ.LedgerUI and OMQ.LedgerUI:Resting()
    button.icon:SetAlpha(st.paused and 0.8 or (resting and 0.55 or 1))
    if st.paused then button.z:Show() else button.z:Hide() end
    if #st.differs > 0 then button.dot:Show() else button.dot:Hide() end
    if not st.voting then button.glow:SetAlpha(0) end
end

function M:SetHidden(hidden)
    OMQ.db.minimap.hidden = hidden and true or false
    if button then
        if OMQ.db.minimap.hidden then button:Hide() else button:Show() end
    end
end

OMQ:RegisterCommand("minimap", function()
    OMQ.db.minimap.hidden = not OMQ.db.minimap.hidden
    if OMQ.db.minimap.hidden then button:Hide() else button:Show() end
    OMQ:Print("minimap icon " .. (OMQ.db.minimap.hidden and "hidden" or "shown"))
end, "show or hide the minimap icon")
