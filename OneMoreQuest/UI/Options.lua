-- One More Quest: quick options (right click on the minimap button)
-- One master switch per category and a snooze button. Everything else lives in
-- the full options window (shift + right click), see Settings.lua.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local W, ROW_H, PAD = 220, 24, 12

local O = {}
OMQ.Options = O

local frame, rows, snoozeBtn, bookBtn, baseH

local function makeCheck(parent, text, get, set)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(W - 2 * PAD, ROW_H)
    row.box = row:CreateTexture(nil, "ARTWORK")
    row.box:SetSize(16, 16)
    row.box:SetPoint("LEFT", 0, 0)
    row.fill = row:CreateTexture(nil, "OVERLAY")
    row.fill:SetSize(10, 10)
    row.fill:SetPoint("CENTER", row.box, "CENTER")
    row.box:SetColorTexture(0.63, 0.50, 0.21, 1)       -- every switch here is a master switch (decision 192)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("LEFT", row.box, "RIGHT", 8, 0)
    row.label:SetText(text)
    row.get, row.set = get, set
    function row:Refresh()
        if self.get() then self.fill:SetColorTexture(0.42, 0.80, 0.36, 1)
        else self.fill:SetColorTexture(0.62, 0.17, 0.14, 1) end
    end
    row:SetScript("OnClick", function(self) self.set(not self.get()); O:Refresh(); OMQ:Fire("SETTINGS_CHANGED", "quick") end)
    return row
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestOptions", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0.07, 0.08, 0.105, 1)
    frame.edge = frame:CreateTexture(nil, "BORDER")
    frame.edge:SetPoint("TOPLEFT"); frame.edge:SetPoint("TOPRIGHT"); frame.edge:SetHeight(3)
    frame.edge:SetColorTexture(0.89, 0.71, 0.29, 1)

    local y = -PAD - 4
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD, y)
    title:SetText("One More Quest")
    local close = CreateFrame("Button", nil, frame)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -6, -8)
    local cx = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cx:SetPoint("CENTER"); cx:SetText("x"); cx:SetTextColor(0.55, 0.58, 0.63)
    close:SetScript("OnClick", function() O:Hide() end)
    y = y - 34

    rows = {}
    for _, m in ipairs(OMQ.Settings.masters) do
        local id = m.id
        local r = makeCheck(frame, m.label,
            function() return OMQ.Settings:MasterGet(id) end,
            function(v) OMQ.Settings:MasterSet(id, v) end)
        r:SetPoint("TOPLEFT", PAD, y)
        rows[#rows + 1] = r
        y = y - ROW_H
    end
    y = y - 8

    snoozeBtn = CreateFrame("Button", nil, frame)
    snoozeBtn:SetSize(W - 2 * PAD, 28)
    snoozeBtn:SetPoint("TOPLEFT", PAD, y)
    snoozeBtn.bg = snoozeBtn:CreateTexture(nil, "BACKGROUND")
    snoozeBtn.bg:SetAllPoints()
    snoozeBtn.bg:SetColorTexture(0.16, 0.18, 0.23, 1)
    snoozeBtn.label = snoozeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    snoozeBtn.label:SetPoint("CENTER")
    snoozeBtn:SetScript("OnClick", function()
        OMQ.Settings:SnoozeToggle()
        O:Refresh()
        OMQ:Fire("SETTINGS_CHANGED", "quick")
    end)
    y = y - 28

    -- opens the journal; only there once its first tab is open (Stats/Ledger.lua)
    bookBtn = CreateFrame("Button", nil, frame)
    bookBtn:SetSize(W - 2 * PAD, 28)
    bookBtn:SetPoint("TOPLEFT", PAD, y - 6)
    bookBtn.bg = bookBtn:CreateTexture(nil, "BACKGROUND")
    bookBtn.bg:SetAllPoints()
    bookBtn.bg:SetColorTexture(0.24, 0.19, 0.09, 1)
    bookBtn.label = bookBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bookBtn.label:SetPoint("CENTER")
    bookBtn.label:SetText("Forever Journey")
    bookBtn:SetScript("OnClick", function()
        O:Hide()
        if OMQ.LedgerUI then OMQ.LedgerUI:Toggle() end
    end)
    baseH = -y + PAD

    frame:SetSize(W, baseH)
    frame.elapsed = 0
    frame:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed > 1 then self.elapsed = 0; O:Refresh() end
    end)
    O.ui = { frame = frame, rows = rows, snooze = snoozeBtn, book = bookBtn }
    frame:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestOptions") end
end

function O:Refresh()
    if not frame then return end
    for _, r in ipairs(rows) do r:Refresh() end
    snoozeBtn.label:SetText(OMQ.Settings:SnoozeLabel("Snooze"))
    local open = OMQ.Ledger and OMQ.Ledger:Open()
    if open then bookBtn:Show() else bookBtn:Hide() end
    frame:SetSize(W, baseH + (open and 34 or 0))
end

function O:Show()
    if not frame then build() end
    frame:ClearAllPoints()
    frame:SetPoint("TOPRIGHT", Minimap or UIParent, "BOTTOMRIGHT", 0, -12)
    self:Refresh()
    frame:Show()
end

function O:Hide() if frame then frame:Hide() end end

function O:Toggle()
    if frame and frame:IsShown() then self:Hide() else self:Show() end
end

OMQ:On("MINIMAP_RIGHT_CLICK", function() O:Toggle() end)
OMQ:RegisterCommand("options", function() O:Toggle() end, "open the options menu")
