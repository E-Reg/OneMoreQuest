-- One More Quest: flight quiz window (reads Stats/Quiz.lua)
-- Phases: invite (play or not), question (four answers, the subject's 3D model or icon), answered (right in green,
-- a wrong pick in red, every option with its value, Next), done (what the flight brought) and landed (too early).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local W = {}
OMQ.QuizUI = W
local Q = OMQ.Quiz

local WIDTH, SMALL, PAD = 560, 390, 20
local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil
local EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local TITLE_FONT, BODY_FONT = "Fonts\\MORPHEUS.TTF", "Fonts\\FRIZQT__.TTF"
local GOLD = { 1, .82, 0 }
local EDGE_GOLD = { .78, .64, .29 }
local EDGE_PLAIN = { .42, .35, .18 }
local RIGHT = { .25, .75, .25 }
local WRONG = { .88, .28, .28 }
local OPEN = { .23, .23, .25 }
local TEXT = { .9, .9, .9 }
local DIM = { .55, .55, .55 }
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
    -- hover: brighter face, gold edge, white text
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

-- the 3D model of a creature, else an icon; a model the client does not know falls back to the icon
W.models = { ok = 0, miss = 0 }
local function picture(parent, size)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(size, size)
    p.bg = p:CreateTexture(nil, "BACKGROUND"); p.bg:SetAllPoints(); p.bg:SetColorTexture(.18, .21, .27, 1)
    p.icon = p:CreateTexture(nil, "ARTWORK"); p.icon:SetPoint("TOPLEFT", 3, -3); p.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    p.model = CreateFrame("PlayerModel", nil, p); p.model:SetAllPoints()
    p.model:Hide()
    return p
end
local function setPicture(p, model, icon)
    p.shown = model or icon
    if not (model or icon) then p:Hide(); return false end
    p:Show()
    p.icon:SetTexture(icon or (I .. "INV_Misc_QuestionMark"))
    p.icon:Show(); p.model:Hide()
    if not (model and p.model.SetCreature) then return true end
    if not pcall(p.model.SetCreature, p.model, model) then return true end
    if p.model.SetPortraitZoom then pcall(p.model.SetPortraitZoom, p.model, 0.6) end
    p.model:Show(); p.icon:Hide()
    p.want = model
    C_Timer.After(0.6, function()
        if p.want ~= model then return end
        local file = p.model.GetModelFileID and select(2, pcall(p.model.GetModelFileID, p.model))
        if type(file) == "number" and file > 0 then W.models.ok = W.models.ok + 1
        else W.models.miss = W.models.miss + 1; p.model:Hide(); p.icon:Show() end
    end)
    return true
end
W._SetPicture = setPicture

function W:Build()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "OneMoreQuestQuiz", UIParent, BACKDROP)
    boxed(f)
    setEdge(f, EDGE_GOLD)
    f:SetFrameStrata("DIALOG")
    f:SetPoint("TOP", UIParent, "TOP", 0, -110)
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnHide", function() if not W.updating and Q.run then Q:Decline() end end)
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestQuiz") end

    f.title = font(f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 19)
    f.title:SetPoint("TOPLEFT", PAD, -16)
    color(f.title, GOLD)
    f.streak = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 12)
    f.streak:SetPoint("TOPRIGHT", -PAD, -20)
    f.dots = {}
    for i = 1, Q.QUESTIONS do
        local d = f:CreateTexture(nil, "ARTWORK")
        d:SetSize(12, 12)
        f.dots[i] = d
    end

    -- invite
    f.inv = CreateFrame("Frame", nil, f); f.inv:SetAllPoints()
    f.invIcon = f.inv:CreateTexture(nil, "ARTWORK"); f.invIcon:SetSize(48, 48); f.invIcon:SetPoint("TOP", 0, -18)
    f.invIcon:SetTexture(I .. "Ability_Mount_Wyvern_01")
    f.play = button(f.inv, 130, 36, "Play", true); f.play:SetPoint("TOPRIGHT", f.inv, "TOP", -6, -106)
    f.play:SetScript("OnClick", function() Q:Play() end)
    f.notNow = button(f.inv, 130, 36, "Not now"); f.notNow:SetPoint("TOPLEFT", f.inv, "TOP", 6, -106)
    f.notNow:SetScript("OnClick", function() Q:Decline() end)
    -- from level 30: Quiz and Rhythm side by side, Not now below
    f.rhythm = button(f.inv, 130, 36, "Rhythm", true); f.rhythm:SetPoint("TOPLEFT", f.inv, "TOP", 6, -106)
    f.rhythm:SetScript("OnClick", function() Q:Rhythm() end)

    -- question
    f.qp = CreateFrame("Frame", nil, f); f.qp:SetAllPoints()
    f.subject = picture(f.qp, 56); f.subject:SetPoint("TOPLEFT", PAD, -48)
    f.qtext = font(f.qp:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge"), BODY_FONT, 16)
    f.qtext:SetJustifyH("LEFT")
    f.opts = {}
    local ow = (WIDTH - 2 * PAD - 10) / 2
    for i = 1, 4 do
        local o = CreateFrame("Button", nil, f.qp, BACKDROP)
        boxed(o, .12, .12, .13)
        o:SetSize(ow, 72)
        o.pic = picture(o, 60); o.pic:SetPoint("LEFT", 6, 0)
        o.label = font(o:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 13)
        o.label:SetJustifyH("LEFT")
        o.sub = font(o:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
        o.sub:SetJustifyH("LEFT")
        o:SetScript("OnClick", function() Q:Answer(i) end)
        o:SetScript("OnEnter", function(self)
            if Q.run and Q.run.phase == "question" then setEdge(self, GOLD); setBg(self, .2, .18, .1); color(self.label, { 1, 1, 1 }) end
        end)
        o:SetScript("OnLeave", function(self)
            if Q.run and Q.run.phase == "question" then setEdge(self, EDGE_PLAIN); setBg(self, .12, .12, .13); color(self.label, TEXT) end
        end)
        f.opts[i] = o
    end
    f.verdict = font(f.qp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), BODY_FONT, 15)
    f.verdict:SetPoint("BOTTOMLEFT", PAD, 22)
    f.reveal = font(f.qp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 12)
    f.reveal:SetPoint("BOTTOMLEFT", f.verdict, "TOPLEFT", 0, 6); f.reveal:SetWidth(WIDTH - 2 * PAD); f.reveal:SetJustifyH("LEFT")
    f.next = button(f.qp, 140, 32, "Next question", true); f.next:SetPoint("BOTTOMRIGHT", -PAD, 14)
    f.next:SetScript("OnClick", function() Q:Next() end)

    -- done / landed
    f.dp = CreateFrame("Frame", nil, f); f.dp:SetAllPoints()
    f.big = font(f.dp:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"), BODY_FONT, 22)
    f.big:SetPoint("TOPLEFT", PAD, -70)
    f.lines = font(f.dp:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 13)
    f.lines:SetPoint("TOPLEFT", f.big, "BOTTOMLEFT", 0, -10); f.lines:SetWidth(SMALL - 2 * PAD); f.lines:SetJustifyH("LEFT")
    f.close = button(f.dp, 110, 32, "Close"); f.close:SetPoint("BOTTOMRIGHT", -PAD, 16)
    f.close:SetScript("OnClick", function() Q:Decline() end)

    -- hidden while it is built: that is no "close" (the first quiz would end at once)
    self.updating = true
    f:Hide()
    self.updating = false
    self.frame = f
    return f
end

local function placeDots(f, run)
    for i, d in ipairs(f.dots) do
        d:ClearAllPoints()
        d:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(PAD + 74 + (Q.QUESTIONS - i) * 16), -22)
        local res = run.results and run.results[i]
        local c = OPEN
        if res == true then c = RIGHT elseif res == false then c = WRONG
        elseif i == run.i and run.phase == "question" then c = GOLD end
        d:SetColorTexture(c[1], c[2], c[3], 1)
        d:SetShown(run.phase ~= "invite")
    end
end

function W:Refresh()
    local run = Q.run
    if not run then
        if self.frame and self.frame:IsShown() then self.updating = true; self.frame:Hide(); self.updating = false end
        return
    end
    local f = self:Build()
    local rec = Q:Record() or {}
    f.inv:Hide(); f.qp:Hide(); f.dp:Hide()
    f.streak:SetText(run.phase ~= "invite" and ("Streak " .. (rec.streak or 0)) or "")
    color(f.streak, (rec.streak or 0) > 0 and GOLD or DIM)
    if run.phase == "invite" then
        f:SetSize(SMALL, 160)
        f.title:ClearAllPoints(); f.title:SetPoint("TOP", 0, -72)
        f.title:SetText(run.rhythm and "Flight Games" or "Flight Quiz")
        f.inv:Show()
        f.notNow.label:SetText("Not now (" .. math.max(0, math.ceil(Q.INVITE_TIME - (GetTime() - run.at))) .. ")")
        f.play.label:SetText(run.rhythm and "Quiz" or "Play")
        if run.short then f.play:Hide() else f.play:Show() end
        if run.rhythm then f.rhythm:Show() else f.rhythm:Hide() end
        f.play:ClearAllPoints(); f.rhythm:ClearAllPoints(); f.notNow:ClearAllPoints()
        if run.rhythm then
            f:SetSize(SMALL, 200)
            if run.short then f.rhythm:SetPoint("TOP", f.inv, "TOP", 0, -106)
            else f.play:SetPoint("TOPRIGHT", f.inv, "TOP", -6, -106); f.rhythm:SetPoint("TOPLEFT", f.inv, "TOP", 6, -106) end
            f.notNow:SetPoint("TOP", f.inv, "TOP", 0, -150)
        else
            f.play:SetPoint("TOPRIGHT", f.inv, "TOP", -6, -106)
            f.notNow:SetPoint("TOPLEFT", f.inv, "TOP", 6, -106)
        end
        for _, d in ipairs(f.dots) do d:Hide() end
    elseif run.phase == "question" or run.phase == "answered" then
        local q = Q:Current()
        f:SetSize(WIDTH, 380)
        f.title:ClearAllPoints(); f.title:SetPoint("TOPLEFT", PAD, -16)
        f.title:SetText("Flight Quiz · " .. run.i .. " / " .. #run.list)
        f.qp:Show()
        local hasPic = setPicture(f.subject, q.model, q.icon)
        f.qtext:ClearAllPoints()
        f.qtext:SetPoint("TOPLEFT", hasPic and (PAD + 68) or PAD, -54)
        f.qtext:SetWidth(WIDTH - 2 * PAD - (hasPic and 68 or 0))
        f.qtext:SetText(q.text)
        local answered = run.phase == "answered"
        local ow = (WIDTH - 2 * PAD - 10) / 2
        for i, o in ipairs(f.opts) do
            local opt = q.options[i]
            o:ClearAllPoints()
            o:SetPoint("TOPLEFT", f.qp, "TOPLEFT", PAD + ((i - 1) % 2) * (ow + 10), -116 - math.floor((i - 1) / 2) * 80)
            if opt then
                o:Show()
                local pic = setPicture(o.pic, opt.model, opt.icon)
                local x = pic and 74 or 12
                o.label:ClearAllPoints(); o.label:SetPoint("LEFT", x, answered and opt.sub and 8 or 0); o.label:SetWidth(ow - x - 8)
                o.label:SetText(opt.label)
                o.sub:ClearAllPoints(); o.sub:SetPoint("TOPLEFT", o.label, "BOTTOMLEFT", 0, -3)
                o.sub:SetText(answered and opt.sub or "")
                o:EnableMouse(not answered)
                if answered and i == q.right then setEdge(o, RIGHT); setBg(o, .08, .19, .1); color(o.label, { 1, 1, 1 }); color(o.sub, { .56, .88, .56 })
                elseif answered and i == run.choice then setEdge(o, WRONG); setBg(o, .23, .09, .09); color(o.label, { 1, 1, 1 }); color(o.sub, { 1, .6, .6 })
                elseif answered then setEdge(o, OPEN); setBg(o, .09, .09, .1); color(o.label, DIM); color(o.sub, DIM)
                else setEdge(o, EDGE_PLAIN); setBg(o, .12, .12, .13); color(o.label, TEXT) end
            else
                o:Hide()
            end
        end
        if answered then
            local good = run.choice == q.right
            f.verdict:SetText(good and "Correct!" or "Not quite.")
            color(f.verdict, good and RIGHT or WRONG)
            f.reveal:SetText(q.reveal or "")
            f.next:Show()
            local left = math.max(0, math.ceil(Q.NEXT_TIME - (GetTime() - (run.answeredAt or GetTime()))))
            f.next.label:SetText((run.i >= #run.list and "See result" or "Next question") .. " (" .. left .. ")")
        else
            f.verdict:SetText(""); f.reveal:SetText("")
            f.next:Hide()
        end
    else
        f:SetSize(SMALL, 230)
        f.title:ClearAllPoints(); f.title:SetPoint("TOPLEFT", PAD, -16)
        f.dp:Show()
        if run.phase == "done" then
            f.title:SetText("Flight Quiz · Done")
            f.big:SetText(run.right .. " of " .. run.answered .. " correct")
            local pct = (rec.n or 0) > 0 and math.floor(100 * (rec.r or 0) / rec.n + 0.5) or 0
            f.lines:SetText(string.format("Streak: %d in a row (best %d)\nAll flights: %d of %d right (%d %%)",
                rec.streak or 0, rec.best or 0, rec.r or 0, rec.n or 0, pct))
        else
            f.title:SetText("Flight Quiz · Landed")
            f.big:SetText(run.right .. " of " .. run.answered .. " answered right")
            f.lines:SetText("You landed before all " .. Q.QUESTIONS .. " questions. This flight does not count for flight cards. Your answers still count for the streak.")
        end
        f.streak:SetText("")
        f.close.label:SetText("Close (" .. math.max(0, math.ceil(Q.CLOSE_TIME - (GetTime() - (run.endAt or GetTime())))) .. ")")
    end
    placeDots(f, run)
    if not f:IsShown() then f:Show() end
end

function W:SafeRefresh()
    local fine, err = pcall(self.Refresh, self)
    if not fine then OMQ:Error("quiz window", err) end
end

OMQ:On("QUIZ_CHANGED", function() W:SafeRefresh() end)
OMQ:On("READY", function()
    C_Timer.NewTicker(1, function()
        local p = Q.run and Q.run.phase
        if (p == "invite" or p == "answered" or p == "done" or p == "landed") and W.frame and W.frame:IsShown() then W:SafeRefresh() end
    end)
end)
