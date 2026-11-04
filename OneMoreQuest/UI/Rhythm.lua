-- One More Quest: Spell Rhythm window (reads Stats/Rhythm.lua)
-- Phases: songs (four songs side by side, the spells of this run with their keys), countdown (5 s, the spells once
-- more), play (timeline: icons run from right to left into the hit zone, the key under each icon, combo, progress,
-- perfect/good/miss) and done (share of notes hit, record, the counts, Again / Close).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local W = {}
OMQ.RhythmUI = W
local R = OMQ.Rhythm

local WIDTH, PAD = 560, 20
local LANE_W, LANE_H, HIT_X, ICON = WIDTH - 2 * PAD, 130, 76, 52
local POOL = 16
W.FLASH = 0.25        -- seconds a pressed note flashes before it goes
local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil
local EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local TITLE_FONT, BODY_FONT = "Fonts\\MORPHEUS.TTF", "Fonts\\FRIZQT__.TTF"
local GOLD = { 1, .82, 0 }
local EDGE_GOLD = { .78, .64, .29 }
local EDGE_PLAIN = { .42, .35, .18 }
local PERFECT = { .25, .75, .25 }
local GOOD = { .56, .72, 1 }
local MISS = { .88, .28, .28 }
local TEXT = { .9, .9, .9 }
local DIM = { .6, .6, .6 }
local I = "Interface\\Icons\\"

local function font(fs, file, size)
    if fs.SetFont then pcall(fs.SetFont, fs, file, size, "") end
    return fs
end
local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end
local function boxed(f, r, g, b)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = EDGE, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropColor(r or .05, g or .05, b or .06, .96)
        f:SetBackdropBorderColor(EDGE_PLAIN[1], EDGE_PLAIN[2], EDGE_PLAIN[3], 1)
    end
end
local function setEdge(f, c) if f.SetBackdropBorderColor then f:SetBackdropBorderColor(c[1], c[2], c[3], 1) end end
local function setBg(f, r, g, b) if f.SetBackdropColor then f:SetBackdropColor(r, g, b, .96) end end

local function button(parent, w, h, text, primary)
    local b = CreateFrame("Button", nil, parent, BACKDROP)
    b:SetSize(w, h)
    boxed(b, primary and .45 or .16, primary and .07 or .16, primary and .07 or .18)
    setEdge(b, primary and EDGE_GOLD or EDGE_PLAIN)
    b.label = font(b:CreateFontString(nil, "OVERLAY", "GameFontNormal"), BODY_FONT, 13)
    b.label:SetPoint("CENTER")
    b.label:SetText(text or "")
    color(b.label, primary and GOLD or TEXT)
    b:SetScript("OnEnter", function(self)
        setBg(self, primary and .62 or .26, primary and .12 or .26, primary and .1 or .28)
        setEdge(self, GOLD); color(self.label, { 1, 1, 1 })
    end)
    b:SetScript("OnLeave", function(self)
        setBg(self, primary and .45 or .16, primary and .07 or .16, primary and .07 or .18)
        setEdge(self, primary and EDGE_GOLD or EDGE_PLAIN); color(self.label, primary and GOLD or TEXT)
    end)
    return b
end
W._Button = button

-- a spell tile: icon with a frame and the key below
local function tile(parent, size)
    local t = CreateFrame("Frame", nil, parent, BACKDROP)
    t:SetSize(size, size)
    boxed(t, .1, .1, .12)
    -- the flash after a key: a coloured frame around the icon (green = hit, red = wrong key)
    t.flash = t:CreateTexture(nil, "BACKGROUND")
    t.flash:SetPoint("TOPLEFT", -4, 4); t.flash:SetPoint("BOTTOMRIGHT", 4, -4)
    t.flash:Hide()
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetPoint("TOPLEFT", 3, -3); t.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    t.key = font(t:CreateFontString(nil, "OVERLAY", "GameFontNormal"), BODY_FONT, 12)
    t.key:SetPoint("TOP", t, "BOTTOM", 0, -3)
    color(t.key, GOLD)
    return t
end

function W:Build()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "OneMoreQuestRhythm", UIParent, BACKDROP)
    boxed(f)
    setEdge(f, EDGE_GOLD)
    f:SetFrameStrata("DIALOG")
    f:SetPoint("TOP", UIParent, "TOP", 0, -110)
    f:SetSize(WIDTH, 300)
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnHide", function() if not W.updating and R.run then R:Stop("close") end end)
    f:SetScript("OnUpdate", function() W:SafeFrame() end)
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestRhythm") end

    f.title = font(f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 19)
    f.title:SetPoint("TOPLEFT", PAD, -16)
    color(f.title, GOLD)
    f.sub = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 12)
    f.sub:SetPoint("TOPRIGHT", -PAD, -20)
    f.close = button(f, 110, 32, "Close")
    f.close:SetPoint("BOTTOMRIGHT", -PAD, 14)
    f.close:SetScript("OnClick", function() R:Stop("close") end)

    -- songs
    f.sp = CreateFrame("Frame", nil, f); f.sp:SetAllPoints()
    f.songs = {}
    local sw = (WIDTH - 2 * PAD - 3 * 12) / 4
    for i = 1, 4 do
        local s = CreateFrame("Button", nil, f.sp, BACKDROP)
        boxed(s, .09, .09, .11)
        s:SetSize(sw, 140)
        s:SetPoint("TOPLEFT", f.sp, "TOPLEFT", PAD + (i - 1) * (sw + 12), -52)
        s.icon = s:CreateTexture(nil, "ARTWORK"); s.icon:SetSize(52, 52); s.icon:SetPoint("TOP", 0, -10)
        s.name = font(s:CreateFontString(nil, "OVERLAY", "GameFontNormal"), BODY_FONT, 13)
        s.name:SetPoint("TOP", s.icon, "BOTTOM", 0, -8); color(s.name, GOLD)
        s.tempo = font(s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
        s.tempo:SetPoint("TOP", s.name, "BOTTOM", 0, -4); color(s.tempo, DIM)
        s.best = font(s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
        s.best:SetPoint("TOP", s.tempo, "BOTTOM", 0, -4); color(s.best, TEXT)
        s:SetScript("OnClick", function() R:Choose(i) end)
        s:SetScript("OnEnter", function(self) if self.ready then setEdge(self, GOLD); setBg(self, .2, .18, .1) end end)
        s:SetScript("OnLeave", function(self) setEdge(self, EDGE_PLAIN); setBg(self, .09, .09, .11) end)
        f.songs[i] = s
    end
    -- Easy / Medium / Hard: one toggle with three parts
    f.modes = {}
    for i, m in ipairs(R.MODES) do
        local b = CreateFrame("Button", nil, f.sp, BACKDROP)
        boxed(b, .12, .12, .13)
        b:SetSize(96, 32)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD + (i - 1) * 100, 14)
        b.label = font(b:CreateFontString(nil, "OVERLAY", "GameFontNormal"), BODY_FONT, 13)
        b.label:SetPoint("CENTER")
        b.label:SetText(m.name)
        b.mode = m
        b:SetScript("OnClick", function() if R:Ready(m) then R:SetMode(m.id) end end)
        b:SetScript("OnEnter", function(self)
            if R.run and R.run.mode ~= m then setEdge(self, GOLD) end
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(m.name .. ": " .. m.n .. " spells")
            GameTooltip:AddLine(R:Ready(m) and "Your most cast spells that have a key on your action bars."
                or ("Put at least " .. m.n .. " spells with a key on your action bars."), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() W:SafeRefresh(); if GameTooltip then GameTooltip:Hide() end end)
        f.modes[i] = b
    end
    f.spellLine = font(f.sp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 12)
    f.spellLine:SetPoint("TOPLEFT", PAD, -202); f.spellLine:SetWidth(WIDTH - 2 * PAD); f.spellLine:SetJustifyH("LEFT")

    -- countdown
    f.cp = CreateFrame("Frame", nil, f); f.cp:SetAllPoints()
    f.count = font(f.cp:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"), TITLE_FONT, 72)
    f.count:SetPoint("TOP", 0, -56); color(f.count, GOLD)
    f.ready = font(f.cp:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 13)
    f.ready:SetPoint("TOP", f.count, "BOTTOM", 0, -4); color(f.ready, DIM)
    f.tiles = {}
    for i = 1, R.SPELLS do
        local t = tile(f.cp, 40)
        t.name = font(t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
        t.name:SetPoint("LEFT", t, "RIGHT", 6, 6); t.name:SetWidth(76); t.name:SetJustifyH("LEFT")
        t.key:ClearAllPoints(); t.key:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -2)
        f.tiles[i] = t
    end

    -- play
    f.pp = CreateFrame("Frame", nil, f); f.pp:SetAllPoints()
    f.bar = f.pp:CreateTexture(nil, "ARTWORK"); f.bar:SetPoint("TOPLEFT", PAD, -46); f.bar:SetSize(LANE_W, 6)
    f.bar:SetColorTexture(.16, .16, .18, 1)
    f.fill = f.pp:CreateTexture(nil, "OVERLAY"); f.fill:SetPoint("TOPLEFT", f.bar, "TOPLEFT"); f.fill:SetSize(1, 6)
    f.fill:SetColorTexture(EDGE_GOLD[1], EDGE_GOLD[2], EDGE_GOLD[3], 1)
    f.lane = CreateFrame("Frame", nil, f.pp, BACKDROP)
    boxed(f.lane, .09, .09, .11)
    f.lane:SetSize(LANE_W, LANE_H); f.lane:SetPoint("TOPLEFT", PAD, -60)
    if f.lane.SetClipsChildren then f.lane:SetClipsChildren(true) end
    f.zone = f.lane:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.zone:SetSize(ICON + 12, LANE_H - 6); f.zone:SetPoint("CENTER", f.lane, "LEFT", HIT_X, 0)
    f.zone:SetColorTexture(1, .82, 0, .1)
    f.zoneL = f.lane:CreateTexture(nil, "ARTWORK"); f.zoneL:SetSize(2, LANE_H - 6); f.zoneL:SetPoint("CENTER", f.lane, "LEFT", HIT_X - ICON / 2 - 6, 0)
    f.zoneL:SetColorTexture(1, .82, 0, 1)
    f.zoneR = f.lane:CreateTexture(nil, "ARTWORK"); f.zoneR:SetSize(2, LANE_H - 6); f.zoneR:SetPoint("CENTER", f.lane, "LEFT", HIT_X + ICON / 2 + 6, 0)
    f.zoneR:SetColorTexture(1, .82, 0, 1)
    f.feedback = font(f.lane:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), BODY_FONT, 14)
    f.feedback:SetPoint("TOP", f.lane, "TOPLEFT", HIT_X, -6)
    f.icons = {}
    for i = 1, POOL do
        local t = tile(f.lane, ICON)
        t:Hide()
        f.icons[i] = t
    end
    f.counts = font(f.pp:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 13)
    f.counts:SetPoint("TOPLEFT", PAD, -202)
    f.hint = font(f.pp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 12)
    f.hint:SetPoint("TOPRIGHT", -PAD, -204); color(f.hint, DIM)

    -- done
    f.dp = CreateFrame("Frame", nil, f); f.dp:SetAllPoints()
    f.pct = font(f.dp:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"), TITLE_FONT, 44)
    f.pct:SetPoint("TOPLEFT", PAD + 6, -60); color(f.pct, GOLD)
    f.recordLine = font(f.dp:CreateFontString(nil, "OVERLAY", "GameFontNormal"), BODY_FONT, 13)
    f.recordLine:SetPoint("TOPLEFT", f.pct, "BOTTOMLEFT", 0, -6)
    f.lines = font(f.dp:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 13)
    f.lines:SetPoint("TOPLEFT", PAD + 190, -62); f.lines:SetWidth(WIDTH - 2 * PAD - 190); f.lines:SetJustifyH("LEFT")
    f.again = button(f.dp, 110, 32, "Again", true)
    f.again:SetPoint("RIGHT", f.close, "LEFT", -10, 0)
    f.again:SetScript("OnClick", function() R:Again() end)

    self.updating = true
    f:Hide()
    self.updating = false
    self.frame = f
    return f
end

local function pctText(n) return n and (n .. "%") or "Not played" end

function W:Refresh()
    local r = R.run
    if not r then
        if self.frame and self.frame:IsShown() then self.updating = true; self.frame:Hide(); self.updating = false end
        return
    end
    local f = self:Build()
    local rec = R:Record() or { best = {} }
    f.sp:Hide(); f.cp:Hide(); f.pp:Hide(); f.dp:Hide()
    f.close:Show()
    f.close.label:SetText("Close")
    if r.phase == "songs" then
        f:SetSize(WIDTH, 280)
        f.title:SetText("Spell Rhythm")
        f.sub:SetText("Pick a song"); color(f.sub, DIM)
        f.sp:Show()
        local enough = R:Ready()
        local best = rec.best[r.mode.id] or {}
        for i, b in ipairs(f.modes) do
            local on, can = r.mode == b.mode, R:Ready(b.mode)
            setEdge(b, on and GOLD or EDGE_PLAIN)
            setBg(b, on and .45 or .12, on and .07 or .12, on and .07 or .13)
            color(b.label, on and GOLD or (can and TEXT or DIM))
        end
        for i, s in ipairs(f.songs) do
            local song = R.SONGS[i]
            local map = OMQ.Beats and OMQ.Beats[song.id]
            s.icon:SetTexture(I .. song.icon)
            s.name:SetText(song.name)
            s.tempo:SetText(song.tempo .. (map and (" · " .. map.bpm .. " BPM") or ""))
            s.best:SetText(best[song.id] and ("Best " .. best[song.id] .. "%") or "Not played")
            s.ready = enough
            s:EnableMouse(enough)
            if s.SetAlpha then s:SetAlpha(enough and 1 or .45) end
        end
        if enough then
            f.spellLine:SetText("While the song runs your keys only play the game. Combat or Esc ends it.")
            color(f.spellLine, DIM)
        else
            f.spellLine:SetText(r.mode.name .. " needs " .. r.mode.n .. " spells with a key on your action bars (you have " .. #r.all .. ").")
            color(f.spellLine, MISS)
        end
    elseif r.phase == "countdown" then
        f.title:SetText(r.song.name)
        local map = OMQ.Beats and OMQ.Beats[r.song.id]
        f.sub:SetText(r.mode.name .. " · " .. (map and (map.bpm .. " BPM · ") or "") .. r.length .. " s"); color(f.sub, DIM)
        f.cp:Show()
        f.ready:SetText("Get ready")
        local tw = (WIDTH - 2 * PAD) / 4
        f:SetSize(WIDTH, #r.spells > 4 and 290 or 240)
        for i, t in ipairs(f.tiles) do
            local sp = r.spells[i]
            t:ClearAllPoints(); t:SetPoint("TOPLEFT", f.cp, "TOPLEFT", PAD + ((i - 1) % 4) * tw, -170 - math.floor((i - 1) / 4) * 54)
            if sp then
                t:Show(); t.icon:SetTexture(sp.icon); t.name:SetText(sp.name); t.key:SetText(R.ShortKey(sp.key))
            else t:Hide() end
        end
        f.close:Hide()
    elseif r.phase == "play" then
        f:SetSize(WIDTH, 240)
        f.title:SetText(r.song.name)
        f.pp:Show()
        f.hint:SetText(r.soundOff and "Sound is off · Esc ends" or "Esc ends")
        f.close:Hide()
    else
        f:SetSize(WIDTH, 230)
        f.title:SetText(r.song.name .. " · Result")
        f.sub:SetText(r.mode.name .. " · " .. #r.notes .. " notes"); color(f.sub, DIM)
        f.dp:Show()
        f.pct:SetText(r.pct .. "%")
        if r.record and r.old then f.recordLine:SetText("New record!"); color(f.recordLine, PERFECT)
        elseif r.record then f.recordLine:SetText("First time!"); color(f.recordLine, PERFECT)
        else f.recordLine:SetText("Record " .. pctText(r.old)); color(f.recordLine, DIM) end
        f.lines:SetText(string.format("Perfect  %d\nGood  %d\nMiss  %d\nBest combo  x%d", r.perfect, r.good, r.miss, r.bestCombo))
        f.close.label:SetText("Close (" .. math.max(0, math.ceil(R.CLOSE_TIME - (GetTime() - (r.endAt or GetTime())))) .. ")")
    end
    self:Frame()
    if not f:IsShown() then f:Show() end
end

-- the parts that move: countdown number, progress, the icons on the timeline, counts and feedback
function W:Frame()
    local f = self.frame
    R:Update()
    local r = R.run
    if not (f and r) then return end
    if r.phase == "countdown" then
        f.count:SetText(tostring(math.max(1, math.ceil(r.goAt - R.Now()))))
        return
    end
    if r.phase ~= "play" then return end
    local t = R:SongTime() or 0
    f.fill:SetWidth(math.max(1, LANE_W * math.min(1, t / r.length)))
    f.sub:SetText("Combo x" .. r.combo); color(f.sub, r.combo > 0 and GOLD or DIM)
    f.counts:SetText(string.format("|cff40bf40Perfect %d|r   |cff8fb8ffGood %d|r   |cffe04848Miss %d|r", r.perfect, r.good, r.miss))
    local span = LANE_W - HIT_X - ICON / 2
    local used = 0
    local nowT = GetTime()
    for i = math.max(1, (r.next or 1) - 8), #r.notes do
        local n = r.notes[i]
        local ahead = n.t - t
        if ahead > R.LOOK then break end
        if used >= POOL then break end
        -- a pressed note stays where it was hit and flashes green (hit) or red (wrong key), then goes
        local flash = n.at and (n.done ~= "miss" or n.wrong) and nowT - n.at < W.FLASH
        if not n.done or flash or (n.done == "miss" and not n.wrong) then
            used = used + 1
            local ic = f.icons[used]
            local sp = r.spells[n.s]
            ic:ClearAllPoints()
            ic:SetPoint("CENTER", f.lane, "LEFT", HIT_X + (flash and n.ahead or ahead) / R.LOOK * span, 6)
            ic.icon:SetTexture(sp and sp.icon)
            ic.key:SetText(sp and R.ShortKey(sp.key) or "")
            if flash then
                local c = n.wrong and MISS or PERFECT
                ic.flash:SetColorTexture(c[1], c[2], c[3], 1)
                ic.flash:Show()
                setEdge(ic, c)
                if ic.SetAlpha then ic:SetAlpha(1 - 0.6 * (nowT - n.at) / W.FLASH) end
            else
                ic.flash:Hide()
                if ic.SetAlpha then ic:SetAlpha(n.done and .3 or 1) end
                setEdge(ic, (not n.done and math.abs(ahead) <= R.GOOD) and GOLD or EDGE_PLAIN)
            end
            ic.note = n
            ic:Show()
        end
    end
    for i = used + 1, POOL do f.icons[i]:Hide() end
    local last = r.last
    if last and GetTime() - last.at < 0.5 then
        f.feedback:SetText(last.how == "perfect" and "Perfect!" or last.how == "good" and "Good" or (last.wrong and "Wrong key" or "Miss"))
        color(f.feedback, last.how == "perfect" and PERFECT or last.how == "good" and GOOD or MISS)
    else
        f.feedback:SetText("")
    end
end

function W:SafeFrame()
    local fine, err = pcall(self.Frame, self)
    if not fine then
        if not self.frameErr then OMQ:Error("rhythm frame", err) end
        self.frameErr = true
    end
end
function W:SafeRefresh()
    local fine, err = pcall(self.Refresh, self)
    if not fine then OMQ:Error("rhythm window", err) end
end

OMQ:On("RHYTHM_CHANGED", function() W:SafeRefresh() end)
OMQ:On("READY", function()
    C_Timer.NewTicker(1, function()
        if R.run and R.run.phase == "done" and W.frame and W.frame:IsShown() then W:SafeRefresh() end
    end)
end)
