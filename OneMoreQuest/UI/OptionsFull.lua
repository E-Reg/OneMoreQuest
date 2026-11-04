-- One More Quest: full options window (shift + right click on the minimap icon)
-- Drawn from the settings registry (Settings.lua); one tab per category (decision 318).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local COL_W, PAD, ROW_H, GAP = 290, 16, 24, 18
local GOLD = { 0.89, 0.71, 0.29 }
local GREY = { 0.6, 0.63, 0.68 }

local F = {}
OMQ.OptionsFull = F

local frame
local widgets = {}

local function tip(widget, text)
    if not text then return end
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function changed() OMQ:Fire("SETTINGS_CHANGED", "full"); F:Refresh() end

-- width an option may use: the column, less the indent
local function widthOf(item) return COL_W - (item.indent and 22 or 0) end

-- lines a check label needs in its column (decision 318): long labels wrap instead of running into the
-- next column; estimated from the length, about 5.8 pixels per character of the game font
local CHAR_W = 5.8
local function checkLines(item)
    local text = type(item.label) == "function" and item.label() or tostring(item.label or "")
    local room = widthOf(item) - 26
    return math.max(1, math.ceil(#text * CHAR_W / room))
end

local function makeCheck(parent, item)
    local row = CreateFrame("Button", nil, parent)
    local lines = item.master and 1 or checkLines(item)
    row:SetSize(widthOf(item), ROW_H + (lines - 1) * 14)
    row.box = row:CreateTexture(nil, "ARTWORK")
    row.box:SetSize(item.master and 18 or 16, item.master and 18 or 16)
    row.box:SetPoint("LEFT", 0, 0)
    if item.master then row.box:SetColorTexture(0.63, 0.50, 0.21, 1)       -- master switch: gold edge (decision 192)
    else row.box:SetColorTexture(0.30, 0.33, 0.40, 1) end
    row.fill = row:CreateTexture(nil, "OVERLAY")
    row.fill:SetSize(item.master and 12 or 10, item.master and 12 or 10)
    row.fill:SetPoint("CENTER", row.box, "CENTER")
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("LEFT", row.box, "RIGHT", 8, 0)
    row.label:SetText(item.label)
    if not item.master then
        row.label:SetWidth(widthOf(item) - 26)
        row.label:SetJustifyH("LEFT")
        if row.label.SetWordWrap then row.label:SetWordWrap(true) end
    end
    row.item = item
    function row:Refresh()
        local on = item.get()
        if item.master then
            if on then self.fill:SetColorTexture(0.42, 0.80, 0.36, 1) else self.fill:SetColorTexture(0.62, 0.17, 0.14, 1) end
        elseif on then self.fill:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        else self.fill:SetColorTexture(0.07, 0.08, 0.105, 1) end
    end
    row:SetScript("OnClick", function() item.set(not item.get()); changed() end)
    tip(row, item.tip)
    return row
end

local function flat(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.16, 0.18, 0.23, 1)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.label:SetPoint("CENTER")
    b:SetScript("OnEnter", function(self) self.bg:SetColorTexture(0.22, 0.25, 0.31, 1) end)
    b:SetScript("OnLeave", function(self) self.bg:SetColorTexture(0.16, 0.18, 0.23, 1) end)
    return b
end

-- buttons in the style of the alert cards (decision 247): dark stone, thin gold edge, gold label;
-- hover lights the edge and the stone, a press darkens it
local function edged(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.edges = {}
    for i = 1, 4 do b.edges[i] = b:CreateTexture(nil, "BORDER") end
    local e = b.edges
    e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(1)
    b.shine = b:CreateTexture(nil, "ARTWORK")
    b.shine:SetPoint("TOPLEFT", 1, -1); b.shine:SetPoint("TOPRIGHT", -1, -1); b.shine:SetHeight(math.floor(h / 2))
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.label:SetPoint("CENTER", 0, 0)
    local function paint(state)
        local bg = state == "down" and { 0.05, 0.055, 0.07 } or (state == "hover" and { 0.14, 0.13, 0.11 } or { 0.10, 0.105, 0.13 })
        b.bg:SetColorTexture(bg[1], bg[2], bg[3], 1)
        local ed = state == "idle" and { 0.45, 0.36, 0.16 } or { GOLD[1], GOLD[2], GOLD[3] }
        for _, t in ipairs(b.edges) do t:SetColorTexture(ed[1], ed[2], ed[3], 1) end
        b.shine:SetColorTexture(1, 0.9, 0.6, state == "hover" and 0.07 or 0.03)
        if state == "hover" then b.label:SetTextColor(1, 0.88, 0.55) else b.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) end
        b.label:SetPoint("CENTER", 0, state == "down" and -1 or 0)
    end
    b.paint = paint
    paint("idle")
    b:SetScript("OnEnter", function(self) paint("hover"); if self.tipText then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.tipText, 1, 1, 1, 1, true); GameTooltip:Show() end end)
    b:SetScript("OnLeave", function() paint("idle"); GameTooltip:Hide() end)
    b:SetScript("OnMouseDown", function() paint("down") end)
    b:SetScript("OnMouseUp", function(self) paint(self:IsMouseOver() and "hover" or "idle") end)
    return b
end
F._edged = edged

local function makeButton(parent, item)
    local b = edged(parent, widthOf(item), 28)
    b.tipText = item.tip
    b.item = item
    local function text() return type(item.label) == "function" and item.label() or item.label end
    function b:Refresh() if not b.flash then b.label:SetText(text()) end end
    b:SetScript("OnClick", function(self)
        item.click()
        -- buttons that open another window close the options (decision 252)
        if item.closeOptions then F:Hide(); return end
        if item.done then
            self.flash = true
            self.label:SetText(item.done)
            C_Timer.After(2, function() self.flash = false; self:Refresh() end)
        end
        changed()
    end)
    return b
end

local function makeStep(parent, item)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(COL_W, ROW_H)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("LEFT", 0, 0)
    row.label:SetText(item.label)
    row.item = item
    local plus = flat(row, 22, 20)
    plus:SetPoint("RIGHT", 0, 0)
    plus.label:SetText("+")
    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.value:SetPoint("RIGHT", plus, "LEFT", -6, 0)
    row.value:SetWidth(64)
    row.value:SetJustifyH("CENTER")
    local minus = flat(row, 22, 20)
    minus:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
    minus.label:SetText("-")
    local function bump(d)
        local v = math.max(item.min, math.min(item.max, (item.get() or item.min) + d * item.by))
        item.set(v); changed()
    end
    minus:SetScript("OnClick", function() bump(-1) end)
    plus:SetScript("OnClick", function() bump(1) end)
    function row:Refresh() self.value:SetText(tostring(item.get()) .. " " .. (item.unit or "")) end
    row.minus, row.plus = minus, plus
    return row
end

-- a text field with its label above (item.get / item.set work on the whole text)
local function makeEdit(parent, item)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(COL_W, 50)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("TOPLEFT", 0, -2)
    row.label:SetText(item.label)
    row.item = item
    local box = CreateFrame("EditBox", nil, row)
    box:SetSize(COL_W, 24)
    box:SetPoint("TOPLEFT", 0, -22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(500)
    box:SetFontObject("GameFontHighlight")
    box:SetTextInsets(6, 6, 0, 0)
    box.bg = box:CreateTexture(nil, "BACKGROUND")
    box.bg:SetAllPoints()
    box.bg:SetColorTexture(0.16, 0.18, 0.23, 1)
    local function commit(self) item.set(self:GetText() or "") end
    box:SetScript("OnEnterPressed", function(self) commit(self); self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function(self) commit(self) end)
    box:SetScript("OnEscapePressed", function(self) self:SetText(item.get() or ""); self:ClearFocus() end)
    row.box = box
    tip(box, item.tip)
    function row:Refresh()
        if not box:HasFocus() then box:SetText(item.get() or "") end
    end
    return row
end

-- a picker with small pictures: click the one you want (decisions 197 and 203: arrow style, preferred role)
local TILE_H = 64
local function makeChoice(parent, item)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(COL_W, TILE_H + 22)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("TOPLEFT", 0, -2)
    row.label:SetText(item.label)
    row.item = item
    row.tiles = {}
    local n = math.max(1, #item.options)
    local gap = 8
    local w = math.floor((COL_W - gap * 3) / 4)          -- four tiles fit; fewer stay that size
    for i, opt in ipairs(item.options) do
        local b = CreateFrame("Button", nil, row)
        b:SetSize(w, TILE_H)
        b:SetPoint("TOPLEFT", (i - 1) * (w + gap), -20)
        b.edge = b:CreateTexture(nil, "BACKGROUND")
        b.edge:SetAllPoints()
        b.bg = b:CreateTexture(nil, "BORDER")
        b.bg:SetPoint("TOPLEFT", 2, -2); b.bg:SetPoint("BOTTOMRIGHT", -2, 2)
        b.bg:SetColorTexture(0.11, 0.12, 0.16, 1)
        -- a single icon (a spec) or the two layers of an arrow; the name under it only with item.names
        local size = item.names and 34 or 46
        b.tint = b:CreateTexture(nil, "ARTWORK")
        b.tint:SetSize(size, size)
        b.tint:SetPoint("TOP", 0, item.names and -6 or -(TILE_H - size) / 2)
        if opt.icon then
            b.tint:SetTexture(opt.icon)
        else
            b.tint:SetTexture(opt.tint)
            b.tint:SetVertexColor(1, 0.82, 0.1)          -- the colour of the arrow to a guide target
            b.detail = b:CreateTexture(nil, "OVERLAY")
            b.detail:SetAllPoints(b.tint)
            b.detail:SetTexture(opt.detail)
        end
        b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.name:SetPoint("BOTTOM", 0, 4)
        b.name:SetText(opt.label)
        if not item.names then b.name:Hide() end
        b:SetScript("OnClick", function() item.set(i); changed() end)
        b:SetScript("OnEnter", function(self)
            self.hover = true; row:Refresh()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.tipText or opt.label, 1, 1, 1)
            if item.tip then GameTooltip:AddLine(item.tip, 0.8, 0.8, 0.8, true) end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self) self.hover = false; row:Refresh(); GameTooltip:Hide() end)
        b.index = i
        row.tiles[i] = b
    end
    function row:Refresh()
        local cur = item.get()
        for i, b in ipairs(self.tiles) do
            if i == cur then b.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
            elseif rawget(b, "hover") then b.edge:SetColorTexture(0.45, 0.47, 0.52, 1)
            else b.edge:SetColorTexture(0.20, 0.22, 0.27, 1) end
            if i == cur then b.name:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) else b.name:SetTextColor(0.75, 0.77, 0.8) end
            b:SetAlpha(i == cur and 1 or 0.8)
        end
    end
    return row
end

-- a toggle with a few entries side by side, one is on (decision 209, the tracker background)
local SEG_H = 22
local function makeSegment(parent, item)
    local row = CreateFrame("Frame", nil, parent)
    local width = COL_W - (item.indent and 22 or 0)
    row:SetSize(width, SEG_H + 20)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("TOPLEFT", 0, -2)
    row.label:SetText(item.label)
    row.item = item
    row.segs = {}
    local n = #item.options
    local w = math.floor((width - (n - 1)) / n)
    for i, text in ipairs(item.options) do
        local b = flat(row, w, SEG_H)
        b:SetPoint("TOPLEFT", (i - 1) * (w + 1), -20)
        b.label:SetText(text)
        b:SetScript("OnClick", function() item.set(i); changed() end)
        b:SetScript("OnEnter", function(self)
            rawset(self, "hover", true); row:Refresh()
            if item.tip then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(item.tip, 1, 1, 1, 1, true); GameTooltip:Show() end
        end)
        b:SetScript("OnLeave", function(self) rawset(self, "hover", false); row:Refresh(); GameTooltip:Hide() end)
        row.segs[i] = b
    end
    function row:Refresh()
        local cur = item.get()
        for i, b in ipairs(self.segs) do
            if i == cur then
                b.bg:SetColorTexture(GOLD[1] * 0.55, GOLD[2] * 0.55, GOLD[3] * 0.55, 1)
                b.label:SetTextColor(1, 0.92, 0.7)
            elseif rawget(b, "hover") then
                b.bg:SetColorTexture(0.22, 0.25, 0.31, 1); b.label:SetTextColor(0.9, 0.9, 0.9)
            else
                b.bg:SetColorTexture(0.16, 0.18, 0.23, 1); b.label:SetTextColor(0.7, 0.72, 0.76)
            end
        end
    end
    return row
end

-- Tabs (decision 318): one tab per category, the tabs on top of the window. The window keeps one size
-- (the tallest tab); a tab lays its options out in two columns.
local TAB_H, FOOT_H = 30, 44
local BODY = { 0.07, 0.08, 0.105 }
local STRIP = { 0.04, 0.045, 0.06 }
local DIM_GOLD = { 0.45, 0.36, 0.16 }

local function itemHeight(item)
    if item.type == "button" then return 36 end
    if item.type == "edit" then return 56 end
    if item.type == "choice" then return TILE_H + 30 end
    if item.type == "segment" then return SEG_H + 26 end
    if item.type == "check" then return ROW_H + (checkLines(item) - 1) * 14 end
    return ROW_H
end

local function tabName(title) return title:sub(1, 1) .. title:sub(2):lower() end

-- splits the items of a tab into two columns of about the same height; an indented item stays with the
-- item above it
local function splitColumns(items)
    local total = 0
    for _, it in ipairs(items) do total = total + itemHeight(it) end
    local acc, cut = 0, #items
    for i, it in ipairs(items) do
        acc = acc + itemHeight(it)
        if acc >= total / 2 then
            cut = i
            while items[cut + 1] and items[cut + 1].indent do cut = cut + 1 end
            break
        end
    end
    if #items < 4 then cut = #items end                 -- a short tab stays in one column
    return cut
end

local function makeTab(parent, index, sec, w)
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(w, TAB_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND"); t.bg:SetAllPoints()
    t.top = t:CreateTexture(nil, "BORDER")                 -- gold line on top of the open tab
    t.top:SetPoint("TOPLEFT"); t.top:SetPoint("TOPRIGHT"); t.top:SetHeight(2)
    t.bottom = t:CreateTexture(nil, "BORDER")              -- line under the closed tabs, the open one merges with the body
    t.bottom:SetPoint("BOTTOMLEFT"); t.bottom:SetPoint("BOTTOMRIGHT"); t.bottom:SetHeight(1)
    t.right = t:CreateTexture(nil, "BORDER")               -- thin divider between tabs
    t.right:SetPoint("TOPRIGHT", 0, -6); t.right:SetPoint("BOTTOMRIGHT", 0, 6); t.right:SetWidth(1)
    t.label = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t.label:SetPoint("CENTER", sec.master and -5 or 0, 0)
    t.label:SetText(tabName(sec.title))
    if sec.master then                                     -- a small dot: the category is on (green) or off (red)
        t.dot = t:CreateTexture(nil, "OVERLAY")
        t.dot:SetSize(6, 6)
        t.dot:SetPoint("LEFT", t.label, "RIGHT", 6, 0)
    end
    t.index, t.master = index, sec.master
    function t:Paint(active)
        local hover = rawget(self, "hover")
        if active then
            self.bg:SetColorTexture(BODY[1], BODY[2], BODY[3], 1)
            self.top:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1); self.top:Show()
            self.bottom:Hide()
            self.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        else
            if hover then self.bg:SetColorTexture(0.10, 0.10, 0.12, 1) else self.bg:SetColorTexture(STRIP[1], STRIP[2], STRIP[3], 1) end
            self.top:Hide()
            self.bottom:SetColorTexture(DIM_GOLD[1], DIM_GOLD[2], DIM_GOLD[3], 1); self.bottom:Show()
            if hover then self.label:SetTextColor(1, 0.88, 0.55) else self.label:SetTextColor(GREY[1], GREY[2], GREY[3]) end
        end
        self.right:SetColorTexture(0.16, 0.17, 0.21, 1)
        local dot = rawget(self, "dot")
        if dot then
            if OMQ:Master(self.master) then dot:SetColorTexture(0.42, 0.80, 0.36, 1)
            else dot:SetColorTexture(0.75, 0.22, 0.18, 1) end
        end
    end
    t:SetScript("OnClick", function() F:SelectTab(index) end)
    t:SetScript("OnEnter", function(self) rawset(self, "hover", true); F:PaintTabs() end)
    t:SetScript("OnLeave", function(self) rawset(self, "hover", false); F:PaintTabs() end)
    return t
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestOptionsFull", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(BODY[1], BODY[2], BODY[3], 1)
    -- a thin dim gold frame around the window
    frame.border = {}
    for i = 1, 4 do frame.border[i] = frame:CreateTexture(nil, "BORDER"); frame.border[i]:SetColorTexture(0.30, 0.25, 0.13, 1) end
    local e = frame.border
    e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(1)

    local width = PAD * 2 + COL_W * 2 + GAP
    local sections = OMQ.Settings:Sections()

    -- the tab strip, right at the top; the close button at its right end
    local CLOSE_W = 34
    local strip = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    strip:SetPoint("TOPLEFT", 1, -1); strip:SetPoint("TOPRIGHT", -1, -1); strip:SetHeight(TAB_H)
    strip:SetColorTexture(STRIP[1], STRIP[2], STRIP[3], 1)
    local tabW = math.floor((width - 2 - CLOSE_W) / #sections)
    local tabs = {}
    for i, sec in ipairs(sections) do
        local t = makeTab(frame, i, sec, tabW)
        t:SetPoint("TOPLEFT", 1 + (i - 1) * tabW, -1)
        tabs[i] = t
    end
    local closeLine = frame:CreateTexture(nil, "BORDER")
    closeLine:SetPoint("TOPLEFT", 1 + #sections * tabW, -1 - TAB_H + 1); closeLine:SetPoint("TOPRIGHT", -1, -1 - TAB_H + 1)
    closeLine:SetHeight(1); closeLine:SetColorTexture(DIM_GOLD[1], DIM_GOLD[2], DIM_GOLD[3], 1)
    local close = CreateFrame("Button", nil, frame)
    close:SetSize(CLOSE_W, TAB_H)
    close:SetPoint("TOPRIGHT", -1, -1)
    local cx = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cx:SetPoint("CENTER", 0, 1); cx:SetText("x"); cx:SetTextColor(0.55, 0.58, 0.63)
    close:SetScript("OnEnter", function() cx:SetTextColor(1, 0.88, 0.55) end)
    close:SetScript("OnLeave", function() cx:SetTextColor(0.55, 0.58, 0.63) end)
    close:SetScript("OnClick", function() F:Hide() end)

    -- the content of every tab; only the open tab is shown
    local top = -1 - TAB_H - PAD
    local tallest = 0
    for ti, sec in ipairs(sections) do
        local y = top
        if sec.master then
            local id = sec.master
            local m = makeCheck(frame, { label = "All of " .. tabName(sec.title) .. " (master switch)", master = true,
                get = function() return OMQ.Settings:MasterGet(id) end,
                set = function(v) OMQ.Settings:MasterSet(id, v) end,
                tip = "Master switch: off disables this whole category, whatever the options below say." })
            m:SetPoint("TOPLEFT", PAD, y)
            m.label:SetFontObject("GameFontNormal")
            m.tab = ti
            widgets[#widgets + 1] = m
            local line = frame:CreateTexture(nil, "ARTWORK")
            line:SetPoint("TOPLEFT", PAD, y - ROW_H - 6)
            line:SetSize(width - PAD * 2, 1)
            line:SetColorTexture(0.17, 0.18, 0.23, 1)
            widgets[#widgets + 1] = { tab = ti, SetShown = function(_, v) if v then line:Show() else line:Hide() end end }
            y = y - ROW_H - 16
        end
        local cut = splitColumns(sec.items)
        local ys = { y, y }
        for i, item in ipairs(sec.items) do
            local col = i <= cut and 1 or 2
            local x = PAD + (col - 1) * (COL_W + GAP)
            local w
            if item.type == "check" then w = makeCheck(frame, item)
            elseif item.type == "step" then w = makeStep(frame, item)
            elseif item.type == "edit" then w = makeEdit(frame, item)
            elseif item.type == "choice" then w = makeChoice(frame, item)
            elseif item.type == "segment" then w = makeSegment(frame, item)
            else w = makeButton(frame, item) end
            w:SetPoint("TOPLEFT", x + (item.indent and 22 or 0), ys[col])
            w.master = sec.master
            w.tab = ti
            widgets[#widgets + 1] = w
            ys[col] = ys[col] - itemHeight(item)
        end
        tallest = math.max(tallest, top - math.min(ys[1], ys[2]))
    end

    -- footer: the name on the left, the list of everything the addon does on the right (decision 247)
    local height = 1 + TAB_H + tallest + PAD + FOOT_H
    local footLine = frame:CreateTexture(nil, "ARTWORK")
    footLine:SetPoint("BOTTOMLEFT", PAD, FOOT_H); footLine:SetSize(width - PAD * 2, 1)
    footLine:SetColorTexture(0.17, 0.18, 0.23, 1)
    local name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("BOTTOMLEFT", PAD, 15)
    name:SetText("One More Quest " .. (OMQ.version or ""))
    name:SetTextColor(0.55, 0.48, 0.32)
    local list = edged(frame, 180, 26)
    list.label:SetText("List functionality")
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 9)
    list:SetScript("OnClick", function() if OMQ.Features then OMQ.Features:Show() end; F:Hide() end)
    F.ui_list = list

    frame:SetSize(width, height)
    frame.elapsed = 0
    frame:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed > 0.5 then self.elapsed = 0; F:Refresh() end
    end)
    frame:Hide()
    F.ui = { frame = frame, widgets = widgets, tabs = tabs }
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestOptionsFull") end
    local saved = OMQ.db and OMQ.db.options and OMQ.db.options.optionsTab
    F.tab = (type(saved) == "number" and tabs[saved]) and saved or 1
end

function F:PaintTabs()
    if not (F.ui and F.ui.tabs) then return end
    for i, t in ipairs(F.ui.tabs) do t:Paint(i == F.tab) end
end

-- opens a tab; the choice is remembered for the next time
function F:SelectTab(i)
    if not frame then build() end
    if not F.ui.tabs[i] then return end
    F.tab = i
    if OMQ.db and OMQ.db.options then OMQ.db.options.optionsTab = i end
    for _, w in ipairs(widgets) do if w.SetShown then w:SetShown(w.tab == i) end end
    F:PaintTabs()
    F:Refresh()
end

function F:Refresh()
    if not frame or not frame:IsShown() then return end
    for _, w in ipairs(widgets) do
        if w.tab == F.tab then
            if w.Refresh then w:Refresh() end
            if rawget(w, "master") then w:SetAlpha(OMQ:Master(w.master) and 1 or 0.4) end
        end
    end
    F:PaintTabs()
end

function F:Show()
    if not frame then build() end
    if not frame:GetPoint() then frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40) end
    frame:Show()
    self:SelectTab(F.tab or 1)
end

function F:Hide() if frame then frame:Hide() end end

-- a feature opened (UI/Unlock.lua): its options appear, so the window is drawn anew the next time
OMQ:On("UNLOCK", function()
    if not frame then return end
    local open = frame:IsShown()
    frame:Hide()
    frame, widgets = nil, {}
    if open then F:Show() end
end)

function F:Toggle()
    if frame and frame:IsShown() then self:Hide() else self:Show() end
end

OMQ:On("MINIMAP_SHIFT_RIGHT_CLICK", function() F:Toggle() end)
OMQ:RegisterCommand("settings", function() F:Toggle() end, "open the full options window")
