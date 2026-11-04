-- One More Quest: lifetime statistics window (section 7.3)
-- Same grid as the session tooltip: players as columns, statistics as rows.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local LABEL_W, COL_W, ROW_H, HEAD_H, PAD, TITLE_H = 170, 112, 26, 24, 16, 40
local GOLD = { 0.89, 0.71, 0.29 }
local MEDAL = { { 0.89, 0.71, 0.29 }, { 0.76, 0.79, 0.82 }, { 0.79, 0.51, 0.31 } }
local MEDAL_OTHER = { 0.42, 0.45, 0.51 }
local GREY = { 0.6, 0.63, 0.68 }

local W = {}
OMQ.LifetimeWindow = W

local frame
local texts, texs = {}, {}
local tUsed, xUsed = 0, 0

local function newText(font)
    tUsed = tUsed + 1
    local fs = texts[tUsed]
    if not fs then fs = frame.content:CreateFontString(nil, "OVERLAY", font); texts[tUsed] = fs end
    fs:SetFontObject(font)
    fs:ClearAllPoints()
    fs:SetAlpha(1)
    fs:Show()
    return fs
end

local function newTex()
    xUsed = xUsed + 1
    local t = texs[xUsed]
    if not t then t = frame.content:CreateTexture(nil, "BACKGROUND"); texs[xUsed] = t end
    t:ClearAllPoints()
    t:SetAlpha(1)
    t:Show()
    return t
end

local function classColor(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

function W:Render()
    if not frame then return end
    tUsed, xUsed = 0, 0
    for _, fs in ipairs(texts) do fs:Hide() end
    for _, t in ipairs(texs) do t:Hide() end

    local people = OMQ.Lifetime:GetPeople()
    local width = PAD * 2 + LABEL_W + #people * COL_W
    local y = -PAD

    for i, p in ipairs(people) do
        local x = PAD + LABEL_W + (i - 1) * COL_W
        local dim = p.online and 1 or 0.5
        if p.isSelf then
            local t = newTex()
            t:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x, y + 2)
            t:SetSize(COL_W - 4, 36)
            t:SetColorTexture(0.89, 0.71, 0.29, 0.18)
        end
        local n = newText("GameFontNormalLarge")
        n:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x + 4, y)
        n:SetWidth(COL_W - 8)
        n:SetText(p.name or "?")
        n:SetTextColor(classColor(p.class))
        n:SetAlpha(dim)
        local tag = newText("GameFontHighlightSmall")
        tag:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x + 4, y - 18)
        tag:SetWidth(COL_W - 8)
        tag:SetText(p.isSelf and "YOU" or (p.online and "" or "OFFLINE"))
        tag:SetTextColor(GREY[1], GREY[2], GREY[3])
    end
    y = y - 42

    for _, def in ipairs(OMQ.Ranking.lifetimeStats) do
        if def.heading then
            y = y - 4
            local h = newText("GameFontNormalSmall")
            h:SetPoint("TOPLEFT", frame.content, "TOPLEFT", PAD, y)
            h:SetText(string.upper(def.heading))
            h:SetTextColor(0.72, 0.63, 0.42)
            local line = newTex()
            line:SetPoint("TOPLEFT", frame.content, "TOPLEFT", PAD + 150, y - 7)
            line:SetSize(math.max(10, width - PAD * 2 - 150), 1)
            line:SetColorTexture(0.17, 0.18, 0.23, 1)
            y = y - HEAD_H
        else
            local entries = {}
            for _, p in ipairs(people) do entries[#entries + 1] = { id = p.guid, value = p.values[def.key] } end
            local places = OMQ.Ranking.Rank(entries, def.best)

            local label = newText("GameFontHighlight")
            label:SetPoint("TOPLEFT", frame.content, "TOPLEFT", PAD, y - 5)
            label:SetText(def.label)
            label:SetTextColor(0.79, 0.8, 0.84)

            for i, p in ipairs(people) do
                local x = PAD + LABEL_W + (i - 1) * COL_W
                local dim = p.online and 1 or 0.5
                local cell = newTex()
                cell:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x, y)
                cell:SetSize(COL_W - 4, ROW_H - 3)
                if p.isSelf then cell:SetColorTexture(0.89, 0.71, 0.29, 0.18)
                else cell:SetColorTexture(1, 1, 1, 0.04) end
                cell:SetAlpha(dim)

                local v = p.values[def.key]
                local txt = newText("GameFontHighlight")
                txt:SetPoint("LEFT", frame.content, "TOPLEFT", x + 7, y - (ROW_H - 3) / 2)
                txt:SetText(OMQ.Ranking.Format(def, v, def.approx))
                if type(v) ~= "number" then txt:SetTextColor(GREY[1], GREY[2], GREY[3])
                else txt:SetTextColor(0.93, 0.92, 0.89) end
                txt:SetAlpha(dim)

                local place = places[p.guid]
                if place then
                    local rk = newText("GameFontNormalSmall")
                    rk:SetPoint("RIGHT", frame.content, "TOPLEFT", x + COL_W - 11, y - (ROW_H - 3) / 2)
                    rk:SetText(tostring(place))
                    local c = MEDAL[place] or MEDAL_OTHER
                    rk:SetTextColor(c[1], c[2], c[3])
                    rk:SetAlpha(dim)
                end
            end
            y = y - ROW_H
        end
    end

    y = y - 10
    local foot = newText("GameFontHighlightSmall")
    foot:SetPoint("TOP", frame.content, "TOP", 0, y)
    foot:SetText("Dimmed entries are offline: last known values  -  sums cover sessions of 10 minutes and longer")
    foot:SetTextColor(GREY[1], GREY[2], GREY[3])
    y = y - 16 - PAD

    local w = math.max(width, 460)
    frame:SetSize(w, -y + TITLE_H)
    frame.content:SetSize(w, -y)
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestLifetime", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetPoint("CENTER")
    local p = OMQ.db.lifetimeWindow
    if p then frame:ClearAllPoints(); frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end

    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.48, 0.39, 0.2, 1)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.08, 0.105, 1)

    -- title bar: drag handle, title, close
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar:SetHeight(TITLE_H - 4)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() frame:StartMoving() end)
    bar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, rel, x, y = frame:GetPoint()
        OMQ.db.lifetimeWindow = { point or "CENTER", rel or "CENTER", x or 0, y or 0 }
    end)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0.10, 0.12, 0.155, 1)
    local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 16, 0)
    title:SetText("LIFETIME STATISTICS")
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    local close = CreateFrame("Button", nil, bar)
    close:SetSize(36, 36)
    close:SetPoint("RIGHT", -4, 0)
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    x:SetPoint("CENTER")
    x:SetText("x")
    x:SetTextColor(0.6, 0.63, 0.68)
    close:SetScript("OnClick", function() W:Hide() end)

    frame.content = CreateFrame("Frame", nil, frame)
    frame.content:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TITLE_H)

    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc >= 5 then acc = 0; W:Render() end
    end)
    frame:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestLifetime") end
end

function W:Show()
    if not frame then build() end
    OMQ.Lifetime:ScanInBackground()     -- no freeze on open (decision 374), redrawn when done
    self:Render()
    frame:Show()
end

function W:Hide() if frame then frame:Hide() end end

function W:Toggle()
    if frame and frame:IsShown() then self:Hide() else self:Show() end
end

OMQ:On("MINIMAP_LEFT_CLICK", function() W:Toggle() end)

OMQ:On("STATISTICS_SCANNED", function()
    if frame and frame:IsShown() then W:Render() end
end)
