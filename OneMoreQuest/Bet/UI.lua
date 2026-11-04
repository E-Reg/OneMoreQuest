-- One More Quest: Bet Check, the windows (chapter 22)
--   create window   the dice in the check bar: bet kind, my outcome, stake, send
--   invite popup    for the other dads: pick an outcome and bet, or skip (60 s)
--   running strip   one line per running bet above the check bar
--   result popup    who was right, who pays whom (or why the bet is off)
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local UI = {}
OMQ.BetUI = UI

local GOLD = { 0.89, 0.71, 0.29 }
local GREY = { 0.6, 0.63, 0.68 }
local TEXT = { 0.93, 0.92, 0.89 }
local GREEN = { 0.49, 0.78, 0.44 }
local RED = { 0.88, 0.47, 0.42 }
local RESULT_SECONDS = 15

local create, invite, strip, result
local sel = { kind = nil, pick = nil, stake = nil }
local inviteId
local dismissedInvites = {}

local function B() return OMQ.Bets end
local function money(c) return B().Money(c) end

local function classColor(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return TEXT[1], TEXT[2], TEXT[3]
end

local function dadName(guid)
    local m = OMQ:GetSelf()
    if m and guid == m.guid then return m.name, m.class end
    local u = OMQ.users and OMQ.users[guid]
    if u then return u.name or "?", u.class end
    return "?", nil
end

local function colored(guid)
    local name, class = dadName(guid)
    local r, g, b = classColor(class)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, name)
end

local function duration(k)
    if k.untilSession then return "until the session ends" end
    if k.fight then return "the next fight" end
    if k.roll then return "one roll" end
    if k.seconds then return math.floor(k.seconds / 60) .. " minutes" end
    return ""
end
UI.Duration = duration

----------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------
local function panel(name, w, h)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(w, h)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    local border = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -1, 1); border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.48, 0.39, 0.2, 1)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.08, 0.105, 1)
    f.bar = f:CreateTexture(nil, "BORDER")
    f.bar:SetPoint("TOPLEFT"); f.bar:SetPoint("TOPRIGHT"); f.bar:SetHeight(3)
    f.bar:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 14, -12)
    f.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPRIGHT", -34, -16)
    f.sub:SetTextColor(GREY[1], GREY[2], GREY[3])
    local close = CreateFrame("Button", nil, f)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -4, -4)
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    x:SetPoint("CENTER"); x:SetText("x"); x:SetTextColor(0.55, 0.58, 0.63)
    close:SetScript("OnClick", function() f:Hide(); if f.onClose then f.onClose() end end)
    f.close = close
    if name and UISpecialFrames then table.insert(UISpecialFrames, name) end
    f:Hide()
    return f
end

local function text(parent, template, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    local c = color or TEXT
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetJustifyH("LEFT")
    return fs
end

-- a flat button; :SetSelected and :SetEnabledLook change its look
local function button(parent, w, h, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.edge = b:CreateTexture(nil, "BORDER")
    b.edge:SetPoint("BOTTOMLEFT"); b.edge:SetPoint("BOTTOMRIGHT"); b.edge:SetHeight(2)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.label:SetPoint("CENTER")
    b.label:SetText(label or "")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.enabledLook = true
    function b:SetSelected(on)
        self.selected = on and true or false
        if on then
            self.bg:SetColorTexture(0.22, 0.18, 0.09, 1)
            self.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        else
            self.bg:SetColorTexture(0.1, 0.11, 0.145, 1)
            self.edge:SetColorTexture(0.17, 0.19, 0.23, 1)
        end
    end
    function b:SetEnabledLook(on)
        self.enabledLook = on and true or false
        self:SetAlpha(on and 1 or 0.4)
    end
    b:SetSelected(false)
    b:SetScript("OnClick", function(self) if self.enabledLook and onClick then onClick(self) end end)
    return b
end

----------------------------------------------------------------------
-- Create window
----------------------------------------------------------------------
local KIND_W, KIND_H = 230, 24

local function stakeValues()
    local list, max = { 100 }, B().MaxStake()
    for v = 500, max, 500 do list[#list + 1] = v end
    return list
end

local function stepStake(dir)
    local list = stakeValues()
    local idx = 1
    for i, v in ipairs(list) do if v <= (sel.stake or 0) then idx = i end end
    idx = math.max(1, math.min(#list, idx + dir))
    sel.stake = list[idx]
    UI:RefreshCreate()
end

local function buildCreate()
    create = panel("OneMoreQuestBetCreate", 540, 22 + #B().KINDS * (KIND_H + 2) + 50)
    create:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    create.title:SetText("Bet Check")
    create.sub:SetText("you start the bet")
    local head1 = text(create, "GameFontNormalSmall", GREY)
    head1:SetPoint("TOPLEFT", 14, -42); head1:SetText("1 - THE BET")
    create.kinds = {}
    for i, k in ipairs(B().KINDS) do
        local b = button(create, KIND_W, KIND_H, k.name, function() sel.kind = k.id; UI:RefreshCreate() end)
        b.label:ClearAllPoints(); b.label:SetPoint("LEFT", 8, 0)
        b:SetPoint("TOPLEFT", 14, -58 - (i - 1) * (KIND_H + 2))
        b.kind = k.id
        create.kinds[i] = b
    end
    local x = 14 + KIND_W + 18
    local head2 = text(create, "GameFontNormalSmall", GREY)
    head2:SetPoint("TOPLEFT", x, -42); head2:SetText("2 - YOUR OUTCOME")
    create.question = text(create, "GameFontHighlight")
    create.question:SetPoint("TOPLEFT", x, -60); create.question:SetWidth(540 - x - 14)
    create.chips = {}
    for i = 1, 5 do
        local c = button(create, 82, 26, "", function(self) sel.pick = self.guid; UI:RefreshCreate() end)
        c:SetPoint("TOPLEFT", x + ((i - 1) % 3) * 86, -96 - math.floor((i - 1) / 3) * 30)
        create.chips[i] = c
    end
    local head3 = text(create, "GameFontNormalSmall", GREY)
    head3:SetPoint("TOPLEFT", x, -166); head3:SetText("3 - STAKE (THE SAME FOR EVERY DAD)")
    create.less = button(create, 30, 28, "-", function() stepStake(-1) end)
    create.less:SetPoint("TOPLEFT", x, -184)
    create.stake = text(create, "GameFontNormalLarge", GOLD)
    create.stake:SetPoint("LEFT", create.less, "RIGHT", 10, 0); create.stake:SetWidth(110); create.stake:SetJustifyH("CENTER")
    create.more = button(create, 30, 28, "+", function() stepStake(1) end)
    create.more:SetPoint("LEFT", create.stake, "RIGHT", 10, 0)
    create.max = text(create, "GameFontHighlightSmall", GREY)
    create.max:SetPoint("TOPLEFT", x, -220); create.max:SetWidth(540 - x - 14)
    create.send = button(create, 540 - x - 14, 34, "Send to the dads", function()
        local ok, why = B():Start(sel.kind, sel.pick, sel.stake)
        if ok then
            create:Hide()
        else
            create.status:SetText(why or "")
        end
    end)
    create.send:SetPoint("TOPLEFT", x, -246)
    create.send.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    create.status = text(create, "GameFontHighlightSmall", RED)
    create.status:SetPoint("TOPLEFT", x, -288); create.status:SetWidth(540 - x - 14)
    create.note = text(create, "GameFontHighlightSmall", GREY)
    create.note:SetPoint("TOPLEFT", x, -306); create.note:SetWidth(540 - x - 14)
    create.note:SetText("The other dads get 60 s to join. The bet runs when at least 2 dads are in. Picks stay secret.")
end

function UI:RefreshCreate()
    if not (create and create:IsShown()) then return end
    local Bt = B()
    local dads = Bt.Dads()
    sel.kind = sel.kind or Bt.KINDS[1].id
    local max = Bt.MaxStake()
    sel.stake = math.max(100, math.min(sel.stake or math.min(1000, max), max))
    for _, b in ipairs(create.kinds) do
        b:SetSelected(b.kind == sel.kind)
        local ok = Bt:CanStart(b.kind)
        b:SetAlpha(ok and 1 or 0.55)
    end
    local k = Bt.KIND[sel.kind]
    create.question:SetText(k.q .. "\n|cff9aa0aa" .. duration(k) .. (k.letter and " - the letter stays secret until every dad has answered" or "") .. "|r")
    local valid = false
    for i, c in ipairs(create.chips) do
        local d = dads[i]
        if d then
            c.guid = d.guid
            c.label:SetText(d.name)
            c.label:SetTextColor(classColor(d.class))
            c:SetSelected(sel.pick == d.guid)
            if sel.pick == d.guid then valid = true end
            c:Show()
        else
            c.guid = nil
            c:Hide()
        end
    end
    if not valid then sel.pick = nil end
    create.stake:SetText(money(sel.stake))
    create.max:SetText(string.format("Max %s (level %d x 5 silver) - your free gold: %s", money(max),
        UnitLevel("player") or 1, money(math.max(0, Bt.FreeGold()))))
    local ok, why = Bt:CanStart(sel.kind)
    if ok and not sel.pick then why = "Pick an outcome." end
    if ok and Bt.FreeGold() < sel.stake then ok, why = false, "Not enough gold for this stake (open bet debts count too)." end
    create.send:SetEnabledLook(ok and sel.pick ~= nil)
    create.status:SetText(ok and (sel.pick and "" or why) or (why or ""))
end

function UI:ToggleCreate()
    if OMQ.Unlock and not OMQ.Unlock:Has("bets") then OMQ:Print("Bets open at level 5."); return end
    if not create then buildCreate() end
    if create:IsShown() then create:Hide(); return end
    create:Show()
    self:RefreshCreate()
end
function UI:CreateFrame() return create end
function UI:Select(kind, pick, stake) sel.kind, sel.pick, sel.stake = kind, pick, stake; self:RefreshCreate() end

----------------------------------------------------------------------
-- Invite popup
----------------------------------------------------------------------
local function buildInvite()
    invite = panel("OneMoreQuestBetInvite", 380, 210)
    invite:SetPoint("TOP", UIParent, "TOP", 0, -200)
    invite.question = text(invite, "GameFontNormalLarge", TEXT)
    invite.question:SetPoint("TOPLEFT", 14, -40); invite.question:SetWidth(352)
    invite.info = text(invite, "GameFontHighlightSmall", GREY)
    invite.info:SetPoint("TOPLEFT", 14, -64); invite.info:SetWidth(352)
    invite.chips = {}
    for i = 1, 5 do
        local c = button(invite, 82, 26, "", function(self) invite.pick = self.guid; UI:RefreshInvite() end)
        c:SetPoint("TOPLEFT", 14 + ((i - 1) % 4) * 88, -100 - math.floor((i - 1) / 4) * 30)
        invite.chips[i] = c
    end
    invite.note = text(invite, "GameFontHighlightSmall", GREY)
    invite.note:SetPoint("TOPLEFT", 14, -160); invite.note:SetWidth(352)
    invite.bet = button(invite, 170, 30, "Bet", function()
        if invite.pick and inviteId then
            local ok, why = B():Join(inviteId, invite.pick)
            if ok then invite:Hide() else invite.note:SetText(why or "") end
        end
    end)
    invite.bet:SetPoint("BOTTOMLEFT", 14, 10)
    invite.bet.label:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
    invite.skip = button(invite, 170, 30, "Skip", function()
        if inviteId then B():Join(inviteId, nil) end
        invite:Hide()
    end)
    invite.skip:SetPoint("BOTTOMRIGHT", -14, 10)
    invite.onClose = function() if inviteId then dismissedInvites[inviteId] = true end end
    local t = 0
    invite:SetScript("OnUpdate", function(_, e)
        t = t + (e or 0)
        if t < 0.25 then return end
        t = 0
        UI:RefreshInvite()
    end)
end

-- the first offer I have not answered yet
local function openOffer()
    local m = OMQ:GetSelf()
    if not m then return nil end
    for _, b in ipairs(B():List()) do
        if b.state == "join" and b.starter ~= m.guid and b.answers[m.guid] == nil and not dismissedInvites[b.id] then return b end
    end
end

function UI:RefreshInvite()
    if not invite then return end
    local b = inviteId and B():Get(inviteId)
    local m = OMQ:GetSelf()
    if not b or b.state ~= "join" or (m and b.answers[m.guid] ~= nil) or dismissedInvites[b.id] then
        b = openOffer()
        inviteId = b and b.id
        invite.pick = nil
    end
    if not b then invite:Hide(); return end
    local k = B().KIND[b.kind]
    invite.title:SetText("Bet from " .. (b.starterName or "?"))
    invite.sub:SetText(string.format("join within %d s", math.max(0, math.ceil(b.joinUntil - GetTime()))))
    invite.question:SetText(k.name)
    invite.info:SetText(k.q .. "\n" .. duration(k) .. " - stake " .. money(b.stake) ..
        (k.letter and " - the letter is revealed when every dad has answered" or ""))
    local dads = B().Dads()
    for i, c in ipairs(invite.chips) do
        local d = dads[i]
        if d then
            c.guid = d.guid
            c.label:SetText(d.name); c.label:SetTextColor(classColor(d.class))
            c:SetSelected(invite.pick == d.guid)
            c:Show()
        else
            c.guid = nil; c:Hide()
        end
    end
    local rich = B().FreeGold() >= b.stake
    invite.bet.label:SetText("Bet " .. money(b.stake))
    invite.bet:SetEnabledLook(rich and invite.pick ~= nil)
    local ins = {}
    for g, p in pairs(b.answers) do if p then ins[#ins + 1] = (dadName(g)) end end
    table.sort(ins)
    if not rich then
        invite.note:SetText(string.format("Not enough gold: you have %s free, the stake is %s (open bet debts count too).",
            money(math.max(0, B().FreeGold())), money(b.stake)))
        invite.note:SetTextColor(RED[1], RED[2], RED[3])
    else
        invite.note:SetText("In so far: " .. (#ins > 0 and table.concat(ins, ", ") or "nobody") .. ". Picks stay secret until the result.")
        invite.note:SetTextColor(GREY[1], GREY[2], GREY[3])
    end
    if invite.soundFor ~= b.id then
        invite.soundFor = b.id
        if OMQ.Sound then OMQ.Sound:Play("in") end
    end
    invite:Show()
end
function UI:InviteFrame() return invite end
function UI:InviteId() return inviteId end
function UI:InvitePick(guid) if invite then invite.pick = guid; self:RefreshInvite() end end

----------------------------------------------------------------------
-- Running strip above the check bar
----------------------------------------------------------------------
local STRIP_W, LINE_H = 300, 16

local function buildStrip()
    strip = CreateFrame("Frame", "OneMoreQuestBetStrip", UIParent)
    strip:SetSize(STRIP_W, 20)
    strip:SetFrameStrata("HIGH")
    strip:SetClampedToScreen(true)
    strip:EnableMouse(true)
    local bg = strip:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.08, 0.105, 0.92)
    strip.lines = {}
    for i = 1, 3 do
        local l = text(strip, "GameFontHighlightSmall", TEXT)
        l:SetPoint("TOPLEFT", 8, -4 - (i - 1) * LINE_H)
        local r = text(strip, "GameFontHighlightSmall", GREY)
        r:SetPoint("TOPRIGHT", -8, -4 - (i - 1) * LINE_H)
        r:SetJustifyH("RIGHT")
        strip.lines[i] = { l = l, r = r }
    end
    strip:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Running bets")
        for _, b in ipairs(B():Running()) do
            local ins = {}
            for g, p in pairs(b.answers) do if p then ins[#ins + 1] = (dadName(g)) end end
            table.sort(ins)
            GameTooltip:AddLine(B().KIND[b.kind].name .. ": " .. (#ins > 0 and table.concat(ins, ", ") or "nobody in yet"), 0.8, 0.8, 0.8)
        end
        GameTooltip:AddLine("Picks stay secret until the result.", 0.6, 0.63, 0.68)
        GameTooltip:Show()
    end)
    strip:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    local t = 0
    strip:SetScript("OnUpdate", function(_, e)
        t = t + (e or 0)
        if t < 0.5 then return end
        t = 0
        UI:RefreshStrip()
    end)
    strip:Hide()
end

function UI.StripLine(b)
    local k = B().KIND[b.kind]
    local n = 0
    for _, p in pairs(b.answers) do if p then n = n + 1 end end
    local name = k.name .. ((b.state == "active" and b.letter) and (" (" .. b.letter .. ")") or "")
    local tail
    if b.state == "join" then
        tail = string.format("joining %ds", math.max(0, math.ceil(b.joinUntil - GetTime())))
    elseif b.endsAt then
        local left = math.max(0, b.endsAt - GetTime())
        tail = string.format("%d:%02d left", math.floor(left / 60), math.floor(left % 60))
    elseif k.untilSession then tail = "session"
    elseif k.fight then tail = "next fight"
    else tail = "rolling" end
    return name, string.format("%d dads - %s - %s", n, money(b.stake), tail)
end

function UI:RefreshStrip()
    if not strip then return end
    local list = B():Running()
    if #list == 0 then strip:Hide(); return end
    local cb = _G.OneMoreQuestCheckBar
    strip:ClearAllPoints()
    if cb then strip:SetPoint("BOTTOMLEFT", cb, "TOPLEFT", 0, 2)
    else strip:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 160) end
    for i, line in ipairs(strip.lines) do
        local b = list[i]
        if b then
            local l, r = UI.StripLine(b)
            line.l:SetText(l); line.r:SetText(r)
            line.l:Show(); line.r:Show()
        else
            line.l:Hide(); line.r:Hide()
        end
    end
    strip:SetHeight(8 + math.min(#list, 3) * LINE_H)
    strip:Show()
end
function UI:StripFrame() return strip end

----------------------------------------------------------------------
-- Result popup
----------------------------------------------------------------------
local WIN_TITLE = {
    death = "%s died first!", kb = "%s got the killing blow!", near = "%s nearly died first!",
    npc = "%s found the letter first!", player = "%s found the letter first!", run = "%s ran the most!",
    dmg = "%s did the most damage!", fall = "%s took the biggest fall!", loot = "%s looted the most gold!",
    roll = "%s rolled highest!",
}

-- title, sub line and one row per bettor: { guid, pickGuid, net }
function UI.ResultView(b)
    local k = B().KIND[b.kind]
    local names = {}
    for _, g in ipairs(b.winnerDads or {}) do names[#names + 1] = (dadName(g)) end
    local who = table.concat(names, " and ")
    local title, sub
    if b.state == "done" then
        title = string.format(WIN_TITLE[b.kind] or "%s!", who)
        local nW = {}
        for _, p in ipairs(b.pays or {}) do nW[p.to] = true end
        local w = 0
        for _ in pairs(nW) do w = w + 1 end
        local pot = b.stake * #B().Bettors(b)
        sub = string.format("%s - %s each - pot %s, %d winner%s", k.name, money(b.stake), money(pot), w, w == 1 and "" or "s")
    else
        local why = b.reason or "no result"
        if why == "everybody was right" then title = "Everybody was right"
        elseif why == "nobody was right" then title = (who ~= "" and (string.format(WIN_TITLE[b.kind] or "%s!", who) .. " ") or "") .. "Nobody picked it"
        elseif why == "fewer than 2 dads" then title = "Not enough dads. Bet off!"
        else title = "Bet off: " .. why end
        sub = k.name .. " - nobody pays, nobody gets anything"
    end
    if b.letter then sub = sub .. " - the letter was " .. b.letter end
    local rows = {}
    for _, g in ipairs(B().Bettors(b)) do
        local net = 0
        for _, p in ipairs(b.pays or {}) do
            if p.to == g then net = net + p.amount elseif p.from == g then net = net - p.amount end
        end
        local value, src, detail
        for _, e in ipairs(b.finalValues or {}) do if e.guid == g then value, src, detail = e.value, e.src, e.detail end end
        rows[#rows + 1] = { guid = g, pick = b.answers[g], net = net, value = value, src = src, detail = detail }
    end
    return title, sub, rows
end

local function buildResult()
    result = panel("OneMoreQuestBetResult", 440, 120)
    result:SetPoint("TOP", UIParent, "TOP", 0, -160)
    result.title:ClearAllPoints(); result.title:SetPoint("TOPLEFT", 16, -14); result.title:SetWidth(390)
    result.info = text(result, "GameFontHighlightSmall", GREY)
    result.info:SetPoint("TOPLEFT", 16, -40); result.info:SetWidth(408)
    result.rows = {}
    for i = 1, 5 do
        local l = text(result, "GameFontHighlight")
        l:SetPoint("TOPLEFT", 16, -66 - (i - 1) * 18)
        local r = text(result, "GameFontHighlight")
        r:SetPoint("TOPRIGHT", -16, -66 - (i - 1) * 18); r:SetJustifyH("RIGHT")
        result.rows[i] = { l = l, r = r }
    end
    result.foot = text(result, "GameFontHighlightSmall", GREY)
    result.foot:SetWidth(408)
    result:SetScript("OnMouseDown", function() result:Hide() end)
    result:SetScript("OnUpdate", function()
        if result.hideAt and GetTime() >= result.hideAt then result:Hide() end
    end)
end

function UI:ShowResult(id)
    local b = B():Get(id)
    if not b then return end
    if not result then buildResult() end
    local title, sub, rows = UI.ResultView(b)
    result.title:SetText(title)
    result.info:SetText(sub)
    local done = b.state == "done"
    if done then result.bar:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    else result.bar:SetColorTexture(0.44, 0.46, 0.51, 1) end
    local shown = 0
    for i, row in ipairs(result.rows) do
        local r = rows[i]
        if r and (done or b.finalValues) then
            shown = i
            local left = colored(r.guid) .. " bet on " .. colored(r.pick)
            -- what decided, per dad (decisions 223 and 227)
            local v = r.value and UI.FormatValue(b, r) or (b.finalValues and B().KIND[b.kind].mode == "value" and "no value")
            if v then left = left .. " |cffd0d0d0(" .. v .. ")|r" end
            if r.src == "f" then left = left .. " |cffffa040random|r" end
            row.l:SetText(left)
            if r.net > 0 then row.r:SetText("+" .. money(r.net)); row.r:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
            elseif r.net < 0 then row.r:SetText("-" .. money(-r.net)); row.r:SetTextColor(RED[1], RED[2], RED[3])
            else row.r:SetText("0"); row.r:SetTextColor(GREY[1], GREY[2], GREY[3]) end
            row.l:Show(); row.r:Show()
        else
            row.l:Hide(); row.r:Hide()
        end
    end
    result.foot:ClearAllPoints()
    result.foot:SetPoint("TOPLEFT", 16, -66 - shown * 18 - 6)
    result.foot:SetText(done and "The losers pay at their next mailbox. Hover the dice to see open business." or "")
    result:SetHeight(66 + shown * 18 + (done and 34 or 0) + 8)
    result.hideAt = GetTime() + RESULT_SECONDS
    result:Show()
    local m = OMQ:GetSelf()
    if done and m and OMQ.Sound then
        for _, r in ipairs(rows) do if r.guid == m.guid and r.net > 0 then OMQ.Sound:Play("done") end end
    end
    OMQ:Print("Bet: " .. title .. (done and "" or (" (" .. B().KIND[b.kind].name .. ")")))
    local vl = UI.ValuesLine(b)
    if vl then OMQ:Print(vl) end
end
function UI:ResultFrame() return result end

-- one value as text, in the bet's own unit (decision 227)
local function clock(sec)
    sec = math.floor(tonumber(sec) or 0)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end
function UI.FormatValue(b, e)
    local v = tonumber(e.value) or 0
    local k = b.kind
    if k == "roll" then return string.format("rolled %.0f", v)
    elseif k == "run" then return string.format("%.0f yd", v)
    elseif k == "fall" then return v < 0 and "died from the fall" or string.format("%.0f fall damage", v)
    elseif k == "dmg" then return string.format("%.0f damage", v)
    elseif k == "loot" then return money(v)
    elseif k == "death" then return "died after " .. clock(v)
    elseif k == "near" then return "below 20% after " .. clock(v)
    elseif k == "kb" then return "killing blow after " .. clock(v)
    elseif k == "npc" or k == "player" then
        local d = (e.detail and e.detail ~= "") and (e.detail .. " ") or ""
        return "targeted " .. d .. "after " .. clock(v)
    end
    return string.format("%.0f", v)
end

local LINE_LABEL = { roll = "Rolls", run = "Yards walked", fall = "Biggest fall", dmg = "Damage", loot = "Gold looted" }

-- the values that decided, every dad, a random fallback marked (decisions 223 and 227):
-- "Rolls: Karle rolled 78, Melchior rolled 35, Sieglinde rolled 93 (random - roll line not seen)"
-- "Yards walked: Karle 400 yd, Melchior 250 yd, Sieglinde 100 yd"
-- "Decided by: Sieglinde targeted Bandit after 2:14 (letter B)"
function UI.ValuesLine(b)
    if not b.finalValues or #b.finalValues == 0 then return nil end
    local parts = {}
    for _, e in ipairs(b.finalValues) do
        local t = colored(e.guid) .. " " .. UI.FormatValue(b, e)
        if e.src == "f" then t = t .. " |cffffa040(random - roll line not seen)|r" end
        parts[#parts + 1] = t
    end
    local line = (LINE_LABEL[b.kind] or "Decided by") .. ": " .. table.concat(parts, ", ")
    if B().KIND[b.kind].mode == "value" then
        -- bettors without a value
        local have = {}
        for _, e in ipairs(b.finalValues) do have[e.guid] = true end
        for _, g in ipairs(B().Bettors(b)) do
            if not have[g] then line = line .. ", " .. colored(g) .. " no value" end
        end
    end
    if b.letter then line = line .. " (letter " .. b.letter .. ")" end
    return line
end

----------------------------------------------------------------------
-- "Bet starts now" in the middle of the screen (decision 179)
----------------------------------------------------------------------
local START_SECONDS = 8
local GO_LINE = {
    death  = "Stay alive! The first dad to die decides it",
    dmg    = "Most damage in the next fight wins",
    run    = "Run! Most yards in 5 minutes wins",
    near   = "First to drop below 20% health and survive wins",
    npc    = "Find an NPC whose name starts with %s",
    player = "Find a stranger whose name starts with %s",
    fall   = "Biggest fall you survive in 15 minutes wins",
    kb     = "The next killing blow wins",
    loot   = "Most gold looted in 10 minutes wins",
    roll   = "Rolling now - highest roll wins",
}

-- big line, dads line
function UI.StartView(b)
    local k = B().KIND[b.kind]
    local line = GO_LINE[b.kind] or k.q
    if k.letter then line = string.format(line, b.letter or "?") end
    local names = {}
    for _, g in ipairs(B().Bettors(b)) do names[#names + 1] = colored(g) end
    local n = #names
    local info = string.format("%d dads in: %s  -  %s each, pot %s  -  %s", n, table.concat(names, ", "),
        money(b.stake), money(b.stake * n), duration(k))
    return line, info
end

local start
local function buildStart()
    start = CreateFrame("Button", "OneMoreQuestBetStart", UIParent)
    start:SetSize(640, 150)
    start:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    start:SetFrameStrata("FULLSCREEN_DIALOG")
    local border = start:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -2, 2); border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetColorTexture(0.48, 0.39, 0.2, 1)
    local bg = start:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.08, 0.105, 0.96)
    start.head = start:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    start.head:SetPoint("TOP", 0, -16)
    start.head:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    start.head:SetText("BET STARTS NOW!")
    start.line = start:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    start.line:SetPoint("TOP", 0, -56)
    start.line:SetWidth(610)
    start.line:SetTextColor(TEXT[1], TEXT[2], TEXT[3])
    start.info = start:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    start.info:SetPoint("TOP", 0, -90)
    start.info:SetWidth(610)
    start.info:SetTextColor(GREY[1], GREY[2], GREY[3])
    start.hint = start:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    start.hint:SetPoint("BOTTOM", 0, 10)
    start.hint:SetText("click to close")
    start.hint:SetTextColor(0.6, 0.63, 0.68)
    start:SetScript("OnClick", function(self) self:Hide() end)
    start:SetScript("OnUpdate", function(self)
        if self.hideAt and GetTime() >= self.hideAt then self:Hide() end
    end)
    start:Hide()
end

function UI:ShowStart(id)
    local b = B():Get(id)
    if not b or b.state ~= "active" then return end
    if not start then buildStart() end
    local line, info = UI.StartView(b)
    start.line:SetText(line)
    start.info:SetText(info)
    start.hideAt = GetTime() + START_SECONDS
    start:Show()
    if OMQ.Sound then OMQ.Sound:Play("announce") end
end
function UI:StartFrame() return start end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local function involved(b)
    local m = OMQ:GetSelf()
    return m and (b.starter == m.guid or (b.answers[m.guid] ~= nil and b.answers[m.guid] ~= false))
end

OMQ:On("BET_OFFERED", function(id)
    if not invite then buildInvite() end
    UI:RefreshInvite()
    if not strip then buildStrip() end
    UI:RefreshStrip()
end)

OMQ:On("BET_ACTIVE", function(id, on)
    local b = B():Get(id)
    if not b then return end
    if on then
        -- every dad sees the start in the middle of the screen, in or not (decision 179)
        UI:ShowStart(id)
        if involved(b) then
            OMQ:Print("Bet on: " .. B().KIND[b.kind].name .. (b.letter and (" - the secret letter is " .. b.letter .. "!") or ""))
        end
    elseif involved(b) then
        UI:ShowResult(id)
    end
end)

OMQ:On("BET_RESULT", function(id) UI:ShowResult(id) end)

OMQ:On("BETS_CHANGED", function()
    if not strip then buildStrip() end
    UI:RefreshStrip()
    UI:RefreshCreate()
    if invite and invite:IsShown() then UI:RefreshInvite() end
end)
