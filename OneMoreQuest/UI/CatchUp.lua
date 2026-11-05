-- One More Quest: the Catch Up window (CatchUp.lua does the thinking)
-- Opened with /omq catchup. Top: me and the dads with their levels and zones. Below the verdict line
-- in one colour: green "Ready to join", gold "Almost", red "Not yet". Then one row per quest the dads
-- have and I do not, the ones I can take first, then the ones that only wait for a level, then the rest.
-- Every row names what is missing; a click sends the arrow to the quest giver, or to the pre-quest a
-- chain needs first. The window works in the group and alone: without a group the last saved picture
-- of the dads is used, and the header says how old it is.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local W = {}
OMQ.CatchUpWindow = W

local PAD, ROW_H = 12, 17
local WIDTH = 580
local NAME_W, WHO_W = 236, 104
local REFRESH = 5                      -- seconds between two renders while the window is open

local GOLD = { 0.89, 0.71, 0.29 }
local GOLD_LIGHT = { 0.95, 0.82, 0.48 }
local GREY = { 0.60, 0.63, 0.68 }
local DIM = { 0.45, 0.47, 0.5 }
local GREEN = { 0.49, 0.78, 0.44 }
local RED = { 0.92, 0.36, 0.31 }
local WHITE = { 0.93, 0.92, 0.89 }

local STATE_COLOR = { ready = GREEN, soon = GOLD_LIGHT, behind = RED, none = GREY }

local frame, rows, head, verdict, meLine, dadLine, zoneLine, footer, hint, refreshBtn, arrowBtn, copyBtn
local lastRender = -100
local report

local function classColor(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- a dad name in his class colour
local function colorName(m)
    local r, g, b = classColor(m.class)
    return string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5), m.name or "?")
end

local function edge(parent, c, inset)
    for i = 1, 4 do
        local e = parent:CreateTexture(nil, "BORDER")
        e:SetColorTexture(c[1], c[2], c[3], 1)
        if i == 1 then e:SetPoint("TOPLEFT", inset, -inset); e:SetPoint("TOPRIGHT", -inset, -inset); e:SetHeight(1)
        elseif i == 2 then e:SetPoint("BOTTOMLEFT", inset, inset); e:SetPoint("BOTTOMRIGHT", -inset, inset); e:SetHeight(1)
        elseif i == 3 then e:SetPoint("TOPLEFT", inset, -inset); e:SetPoint("BOTTOMLEFT", inset, inset); e:SetWidth(1)
        else e:SetPoint("TOPRIGHT", -inset, -inset); e:SetPoint("BOTTOMRIGHT", -inset, inset); e:SetWidth(1) end
    end
end

local function text(parent, template, c, justify, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    if c then fs:SetTextColor(c[1], c[2], c[3]) end
    fs:SetJustifyH(justify or "LEFT")
    if width then
        fs:SetWidth(width)
        if fs.SetWordWrap then fs:SetWordWrap(false) end
    end
    return fs
end

local function button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

----------------------------------------------------------------------
-- The arrow of a row: the quest giver, or the pre-quest a chain needs
----------------------------------------------------------------------
function W:GoTo(e)
    if not e then return "none" end
    local NQ = OMQ.NextQuest
    local w = e.spot and NQ and NQ.World and NQ.World(e.spot) or nil
    if not w then
        OMQ:Print(string.format("%s: no place known%s", e.title or "this quest",
            e.state == "can" and " - the dads can share it to you" or ""))
        return "none"
    end
    if not OMQ.Guide then return "none" end
    local me = OMQ.CatchUp.Me()
    if me.inst and w[3] ~= me.inst then
        OMQ:Print(string.format("%s is on another continent (%s)", e.spotName or e.title or "that quest",
            OMQ.CatchUp.ZoneName(e.spot[1]) or "?"))
        return "continent"
    end
    local label = "Catch up: " .. (e.spotName or e.title or "quest")
    local what = e.spotName and ("pre-quest of \"" .. (e.title or "?") .. "\" - pick it up here")
        or (e.state == "can" and "quest giver - or let a dad share it" or "quest giver")
    OMQ.Guide:StartAt(label, w[1], w[2], w[3], "catchup", nil, { name = what, radius = 12 })
    if frame then frame:Hide() end                        -- so the arrow can be seen (decision 195)
    OMQ:Print("arrow: " .. label)
    return "arrow"
end

-- the arrow to the nearest dad of the group
function W:GoToDads()
    local rep = report or OMQ.CatchUp:Scan()
    local w = rep.where
    if not (w.who and w.dist and OMQ.Guide) then
        OMQ:Print("catch up: no dad with a known position" .. (w.otherContinent and " on your continent" or ""))
        return false
    end
    OMQ.Guide:StartAt("The dads", w.who.a, w.who.b, w.who.inst, "catchup", nil,
        { name = (w.who.name or "the group") .. " - walk to the group", radius = 30 })
    if frame then frame:Hide() end
    OMQ:Print(string.format("arrow: %s, %d yards away", w.who.name or "the dads", math.floor(w.dist + 0.5)))
    return true
end

----------------------------------------------------------------------
-- Rows
----------------------------------------------------------------------
local function rowTooltip(self)
    local e = self.entry
    if not (e and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.title or "?", GOLD[1], GOLD[2], GOLD[3])
    if e.who and #e.who > 0 then
        GameTooltip:AddLine("has it: " .. table.concat(e.who, ", "), 1, 1, 1)
    end
    local bits = {}
    if e.req then bits[#bits + 1] = "required level " .. e.req end
    if e.qlevel then bits[#bits + 1] = "quest level " .. e.qlevel end
    if e.zone then bits[#bits + 1] = e.zone end
    if #bits > 0 then GameTooltip:AddLine(table.concat(bits, ", "), 0.8, 0.8, 0.8) end
    if e.state == "can" then
        GameTooltip:AddLine("Nothing is missing: a dad can share it, or you take it at the giver.", GREEN[1], GREEN[2], GREEN[3], true)
    else
        for _, b in ipairs(e.blockers or {}) do
            local c = (b.kind == "level") and GOLD_LIGHT or RED
            GameTooltip:AddLine("- " .. b.text, c[1], c[2], c[3], true)
        end
        if e.state == "done" then GameTooltip:AddLine("- " .. (e.why or ""), GREY[1], GREY[2], GREY[3], true) end
    end
    for _, b in ipairs(e.cautions or {}) do
        GameTooltip:AddLine("- " .. b.text, GOLD[1], GOLD[2], GOLD[3], true)
    end
    if e.dungeon then GameTooltip:AddLine("its objectives are in a dungeon", 0.62, 0.8, 0.95, true) end
    if e.pickup then GameTooltip:AddLine("a class quest: it cannot be shared, you pick it up yourself", 0.8, 0.8, 0.8, true) end
    if e.spot then
        GameTooltip:AddLine(e.spotName and ("Click: the arrow to \"" .. e.spotName .. "\", the quest it needs first")
            or "Click: the arrow to the quest giver", GREY[1], GREY[2], GREY[3])
    end
    GameTooltip:Show()
end

local function makeRow(parent, i)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(WIDTH - PAD * 2, ROW_H)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.07)
    b.name = text(b, "GameFontHighlightSmall", WHITE, "LEFT", NAME_W)
    b.name:SetPoint("LEFT", 0, 0)
    b.who = text(b, "GameFontHighlightSmall", DIM, "LEFT", WHO_W)
    b.who:SetPoint("LEFT", b, "LEFT", NAME_W, 0)
    b.miss = text(b, "GameFontHighlightSmall", GREY, "LEFT", WIDTH - PAD * 2 - NAME_W - WHO_W)
    b.miss:SetPoint("LEFT", b, "LEFT", NAME_W + WHO_W, 0)
    b:SetScript("OnEnter", rowTooltip)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:SetScript("OnClick", function(self) W:GoTo(self.entry) end)
    return b
end

----------------------------------------------------------------------
-- The window
----------------------------------------------------------------------
local function build()
    frame = CreateFrame("Frame", "OneMoreQuestCatchUp", UIParent)
    frame:SetSize(WIDTH, 300)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.075, 0.082, 0.11, 0.97)
    edge(frame, { 0.63, 0.50, 0.21 }, 0)
    edge(frame, { 0.29, 0.23, 0.10 }, 3)

    frame.title = text(frame, "GameFontNormalLarge", GOLD_LIGHT)
    frame.title:SetPoint("TOPLEFT", PAD + 4, -PAD)
    frame.title:SetText("Catch Up")
    frame.age = text(frame, "GameFontNormalSmall", DIM, "RIGHT")
    frame.age:SetPoint("TOPRIGHT", -28, -PAD - 2)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() frame:Hide() end)

    meLine = text(frame, "GameFontHighlightSmall", WHITE)
    meLine:SetPoint("TOPLEFT", PAD + 4, -38)
    dadLine = text(frame, "GameFontHighlightSmall", GREY, "LEFT", WIDTH - PAD * 2 - 8)
    dadLine:SetPoint("TOPLEFT", PAD + 4, -53)
    zoneLine = text(frame, "GameFontHighlightSmall", GREY, "LEFT", WIDTH - PAD * 2 - 8)
    zoneLine:SetPoint("TOPLEFT", PAD + 4, -68)
    for _, fs in ipairs({ dadLine, zoneLine }) do         -- both can run long: two lines each
        if fs.SetWordWrap then fs:SetWordWrap(true) end
        if fs.SetMaxLines then pcall(fs.SetMaxLines, fs, 2) end
    end

    verdict = text(frame, "GameFontNormal", GOLD_LIGHT, "LEFT", WIDTH - PAD * 2 - 8)
    verdict:SetPoint("TOPLEFT", PAD + 4, -90)
    if verdict.SetWordWrap then verdict:SetWordWrap(true) end
    if verdict.SetMaxLines then pcall(verdict.SetMaxLines, verdict, 2) end

    head = {}
    head[1] = text(frame, "GameFontNormalSmall", { 0.72, 0.63, 0.42 }, "LEFT", NAME_W)
    head[1]:SetText("THEIR QUEST YOU LACK")
    head[2] = text(frame, "GameFontNormalSmall", { 0.72, 0.63, 0.42 }, "LEFT", WHO_W)
    head[2]:SetText("WHO HAS IT")
    head[3] = text(frame, "GameFontNormalSmall", { 0.72, 0.63, 0.42 }, "LEFT")
    head[3]:SetText("WHAT IS MISSING")

    rows = {}
    for i = 1, OMQ.CatchUp.MAX_ROWS do rows[i] = makeRow(frame, i) end

    footer = text(frame, "GameFontHighlightSmall", GREY, "LEFT", WIDTH - PAD * 2 - 8)
    if footer.SetWordWrap then footer:SetWordWrap(true) end
    if footer.SetMaxLines then pcall(footer.SetMaxLines, footer, 3) end
    hint = text(frame, "GameFontDisableSmall", DIM, "LEFT", WIDTH - PAD * 2 - 8)
    hint:SetText("A click on a row sends the arrow to the quest giver. Levels open quests by themselves - /omq catchup nudge tells you when.")
    if hint.SetWordWrap then hint:SetWordWrap(true) end

    refreshBtn = button(frame, "Refresh", 80, function() W:Render(true) end)
    arrowBtn = button(frame, "Arrow to the dads", 140, function() W:GoToDads() end)
    copyBtn = button(frame, "Copy as text", 110, function()
        local lines = OMQ.CatchUp:Lines(report)
        if OMQ.ShowReport then OMQ:ShowReport(lines) else for _, l in ipairs(lines) do print(l) end end
    end)

    frame:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestCatchUp") end
end

local function dadsText(rep)
    local out = {}
    for _, m in ipairs(rep.members) do
        local bits = colorName(m)
        if m.level then bits = bits .. " " .. m.level end
        if not m.addon then bits = bits .. " (no addon)"
        elseif not m.quests then bits = bits .. " (no list yet)" end
        out[#out + 1] = bits
    end
    if #out == 0 then return "no dads known yet" end
    return "The dads: " .. table.concat(out, ", ")
end

local function zoneText(rep)
    local w = rep.where
    local parts = {}
    if w.zone then
        parts[#parts + 1] = "They are in " .. w.zone ..
            (w.low and string.format(" (level %d-%d)", w.low, w.high or w.low) or "")
    end
    if w.dist then
        parts[#parts + 1] = string.format("%d yards from you", math.floor(w.dist + 0.5))
    elseif w.otherContinent then
        parts[#parts + 1] = "another continent"
    end
    if rep.shareLevel then
        parts[#parts + 1] = string.format("automatic sharing needs level %d (at most %d levels apart)",
            rep.shareLevel, (OMQ.QuestSync and OMQ.QuestSync.LEVEL_GAP) or 5)
    end
    if rep.noAddon > 0 then
        parts[#parts + 1] = string.format("%d without the addon: quests unknown", rep.noAddon)
    end
    return table.concat(parts, "  -  ")
end

function W:Render(force)
    if not frame or not frame:IsShown() then return end
    if not force and GetTime() - lastRender < 0.2 then return end
    lastRender = GetTime()
    local ok, rep = pcall(OMQ.CatchUp.Scan, OMQ.CatchUp)
    if not ok or type(rep) ~= "table" then OMQ:Error("catch up render", rep); return end
    report = rep

    local me = rep.me
    meLine:SetText(string.format("You: %s, level %d%s", me.name or "?", me.level or 1,
        me.zone and (" in " .. me.zone) or ""))
    dadLine:SetText(dadsText(rep))
    zoneLine:SetText(zoneText(rep))
    if rep.source == "saved" then
        frame.age:SetText("last seen " .. OMQ.CatchUp.Ago(rep.savedAt and (time() - rep.savedAt) or nil))
    elseif rep.source == "live" then
        frame.age:SetText("in your group now")
    else
        frame.age:SetText("")
    end

    local c = STATE_COLOR[rep.verdict.state] or GOLD_LIGHT
    verdict:SetText(rep.verdict.text)
    verdict:SetTextColor(c[1], c[2], c[3])

    -- the header lines, one under the other: a line that wraps pushes the rest down
    local y = 36
    local function place(fs, after)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -y)
        local h = (fs:GetText() or "") ~= "" and (fs:GetStringHeight() or 12) or 0
        y = y + h + (h > 0 and after or 0)
    end
    place(meLine, 3)
    place(dadLine, 3)
    place(zoneLine, 8)
    place(verdict, 10)

    -- the rows: what fits, the rest is counted in the footer
    local shown = 0
    local hasRows = #rep.quests > 0
    for i = 1, 3 do if hasRows then head[i]:Show() else head[i]:Hide() end end
    if hasRows then
        head[1]:ClearAllPoints(); head[1]:SetPoint("TOPLEFT", PAD + 4, -y)
        head[2]:ClearAllPoints(); head[2]:SetPoint("TOPLEFT", PAD + 4 + NAME_W, -y)
        head[3]:ClearAllPoints(); head[3]:SetPoint("TOPLEFT", PAD + 4 + NAME_W + WHO_W, -y)
        y = y + 16
    end
    for i, b in ipairs(rows) do
        local e = rep.quests[i]
        if e and i <= OMQ.CatchUp.MAX_ROWS then
            shown = i
            b.entry = e
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -(y + (i - 1) * ROW_H))
            b.name:SetText(e.title or "?")
            local nc = (e.state == "done") and DIM or WHITE
            b.name:SetTextColor(nc[1], nc[2], nc[3])
            b.who:SetText(e.who and table.concat(e.who, ", ") or "-")
            local miss, mc
            if e.state == "can" then
                miss = (e.short or "Can take") .. (e.note and (" - " .. e.note) or "")
                mc = (e.cautions and #e.cautions > 0) and GOLD_LIGHT or GREEN
            elseif e.state == "done" then
                miss, mc = "Done by you", DIM
            elseif e.onlyLevel then
                miss, mc = string.format("Level %d (you are %d)", e.needLevel or 0, me.level or 1), GOLD_LIGHT
            else
                miss, mc = e.short or "?", RED
                if e.needLevel then miss = miss .. " + level " .. e.needLevel end
            end
            b.miss:SetText(miss)
            b.miss:SetTextColor(mc[1], mc[2], mc[3])
            b:Show()
        else
            b.entry = nil
            b:Hide()
        end
    end
    y = y + shown * ROW_H + 6

    local n = rep.counts
    local parts = {}
    if n.total > 0 then
        parts[#parts + 1] = string.format("%d of their quests you lack: %d you can take", n.total, n.can)
        if n.level > 0 then
            parts[#parts + 1] = string.format("%d wait for a level (next %s, all at %s)", n.level,
                rep.nextLevel and tostring(rep.nextLevel) or "?", rep.allLevel and tostring(rep.allLevel) or "?")
        end
        if n.hard > 0 then parts[#parts + 1] = string.format("%d need more than a level", n.hard) end
    end
    if #rep.quests > shown then parts[#parts + 1] = string.format("%d more not shown", #rep.quests - shown) end
    if n.done > 0 then parts[#parts + 1] = string.format("%d you have done already", n.done) end
    if n.mine > 0 then parts[#parts + 1] = string.format("%d quests of yours they lack", n.mine) end
    if #rep.unknown > 0 then parts[#parts + 1] = "no list yet from " .. table.concat(rep.unknown, ", ") end
    footer:ClearAllPoints()
    footer:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -y)
    footer:SetText(table.concat(parts, "  -  "))
    y = y + (footer:GetStringHeight() or 12) + 6

    hint:ClearAllPoints()
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -y)
    y = y + (hint:GetStringHeight() or 24) + 8

    refreshBtn:ClearAllPoints()
    refreshBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -y)
    arrowBtn:ClearAllPoints()
    arrowBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)
    local canWalk = (rep.where.who ~= nil and rep.where.dist ~= nil)
    if arrowBtn.SetEnabled then arrowBtn:SetEnabled(canWalk)
    elseif canWalk then arrowBtn:Enable() else arrowBtn:Disable() end
    copyBtn:ClearAllPoints()
    copyBtn:SetPoint("LEFT", arrowBtn, "RIGHT", 6, 0)
    y = y + 22 + PAD

    frame:SetSize(WIDTH, y)
end

function W:Show()
    if not frame then build() end
    frame:Show()
    self:Render(true)
end

function W:Hide() if frame then frame:Hide() end end
function W:Toggle()
    if frame and frame:IsShown() then frame:Hide() else self:Show() end
end
function W:Frame() return frame end
function W:Report() return report end

-- while the window is open it follows the group: new quest lists, levels and distances
local ticker = CreateFrame("Frame")
local acc = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    if not (frame and frame:IsShown()) then return end
    acc = acc + (elapsed or 0)
    if acc < REFRESH then return end
    acc = 0
    pcall(W.Render, W, true)
end)

OMQ:On("QUESTS_CHANGED", function() if frame and frame:IsShown() then pcall(W.Render, W, true) end end)
