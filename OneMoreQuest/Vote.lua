-- One More Quest: the vote (section 8)
-- "/omq" alone asks the group: One more quest! or Bed time. The popup runs for
-- 60 seconds (or until everybody voted). Votes show as dots only (nobody sees
-- numbers or who voted what). The result appears as a big message in the middle
-- of the screen (click or 10 seconds) and as a chat line. The next vote can
-- start 10 minutes later. No sound.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local DURATION = 60
local COOLDOWN = 600
local MAX_DOTS = 12             -- voters shown as dots
local DOT_SIZE, DOT_GAP = 12, 6
local CHOICES = {
    Q = { text = "One more quest!", color = { 0.49, 0.78, 0.44 } },
    B = { text = "Bed time",        color = { 0.35, 0.65, 0.91 } },
}

local V = {}
OMQ.Vote = V

local vote                      -- the running vote: { id, by, startAt, votes = { guid = "Q"|"B" } }
local lastStart = -math.huge    -- when the last vote started (any starter): the cooldown
local frame

----------------------------------------------------------------------
-- Counting
----------------------------------------------------------------------
local function participants()
    -- everybody who can vote: us and the addon users online in the group
    local n = 1
    for _, u in pairs(OMQ.users or {}) do if OMQ:IsOnline(u) then n = n + 1 end end
    return n
end

local function tally()
    local q, b, total = 0, 0, 0
    for _, c in pairs(vote.votes) do
        total = total + 1
        if c == "Q" then q = q + 1 elseif c == "B" then b = b + 1 end
    end
    return q, b, total
end

----------------------------------------------------------------------
-- Popup
----------------------------------------------------------------------
local function makeButton(parent, choice, x)
    local c = CHOICES[choice]
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(150, 36)
    btn:SetPoint("TOPLEFT", x, -64)
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(c.color[1] * 0.35, c.color[2] * 0.35, c.color[3] * 0.35, 1)
    btn.edge = btn:CreateTexture(nil, "BORDER")
    btn.edge:SetPoint("BOTTOMLEFT"); btn.edge:SetPoint("BOTTOMRIGHT"); btn.edge:SetHeight(3)
    btn.edge:SetColorTexture(c.color[1], c.color[2], c.color[3], 1)
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    btn.label:SetPoint("CENTER")
    btn.label:SetText(c.text)
    btn.label:SetTextColor(0.93, 0.92, 0.89)
    btn:SetScript("OnClick", function() V:Cast(choice) end)
    return btn
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestVote", UIParent)
    frame:SetSize(340, 146)
    frame:SetFrameStrata("DIALOG")
    frame:SetPoint("TOP", UIParent, "TOP", 0, -200)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -1, 1); border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.48, 0.39, 0.2, 1)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.08, 0.105, 1)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOP", 0, -12)
    frame.title:SetTextColor(0.89, 0.71, 0.29)
    frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.sub:SetPoint("TOP", 0, -36)
    frame.sub:SetTextColor(0.6, 0.63, 0.68)
    frame.btnQ = makeButton(frame, "Q", 12)
    frame.btnB = makeButton(frame, "B", 178)
    frame.dots = {}
    for i = 1, MAX_DOTS do
        local d = frame:CreateTexture(nil, "ARTWORK")
        d:SetSize(DOT_SIZE, DOT_SIZE)
        d:SetTexture("Interface\\COMMON\\Indicator-Gray")
        d:Hide()
        frame.dots[i] = d
    end
    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetPoint("BOTTOM", 0, 10)
    frame.status:SetTextColor(0.6, 0.63, 0.68)

    local close = CreateFrame("Button", nil, frame)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -4, -4)
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    x:SetPoint("CENTER"); x:SetText("x"); x:SetTextColor(0.55, 0.58, 0.63)
    close:SetScript("OnClick", function() frame:Hide() end)   -- closing = not voting

    frame:SetScript("OnUpdate", function(_, elapsed) V:Tick() end)
    frame:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestVote") end
end

-- one dot per voter, filled one after the other as votes arrive
local function refreshDots()
    local total = select(3, tally())
    local n = math.min(math.max(participants(), 1), MAX_DOTS)
    local width = n * DOT_SIZE + (n - 1) * DOT_GAP
    for i = 1, MAX_DOTS do
        local d = frame.dots[i]
        if i <= n then
            d:ClearAllPoints()
            d:SetPoint("TOPLEFT", frame, "TOPLEFT", (frame:GetWidth() - width) / 2 + (i - 1) * (DOT_SIZE + DOT_GAP), -112)
            if i <= total then d:SetVertexColor(0.89, 0.71, 0.29, 1) else d:SetVertexColor(0.3, 0.33, 0.4, 1) end
            d:Show()
        else
            d:Hide()
        end
    end
end

local function refresh()
    if not (frame and vote) then return end
    local me = OMQ:GetSelf()
    local mine = me and vote.votes[me.guid]
    frame.title:SetText("What now?")
    frame.sub:SetText("started by " .. (vote.byName or "?"))
    local left = math.max(0, math.ceil(vote.startAt + DURATION - GetTime()))
    if mine then
        frame.status:SetText(string.format("You voted: %s  -  %ds", CHOICES[mine].text, left))
    else
        frame.status:SetText(string.format("%ds", left))
    end
    refreshDots()
    frame.btnQ:SetAlpha(mine == "B" and 0.4 or 1)
    frame.btnB:SetAlpha(mine == "Q" and 0.4 or 1)
end

----------------------------------------------------------------------
-- Life cycle
----------------------------------------------------------------------
local function begin(id, byGuid, byName, startedHere)
    vote = { id = id, by = byGuid, byName = byName, startAt = GetTime(), votes = {} }
    lastStart = GetTime()
    if not frame then build() end
    refresh()
    frame:Show()
    if OMQ.Sound then OMQ.Sound:Play("announce") end
end

-- The result in the middle of the screen: gone on click or after RESULT_SECONDS
local RESULT_SECONDS = 10
local resultFrame, resultToken = nil, 0

local function showResult(text, color)
    if not resultFrame then
        resultFrame = CreateFrame("Button", "OneMoreQuestVoteResult", UIParent)
        resultFrame:SetSize(560, 120)
        resultFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
        resultFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        local border = resultFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
        border:SetPoint("TOPLEFT", -2, 2); border:SetPoint("BOTTOMRIGHT", 2, -2)
        border:SetColorTexture(0.48, 0.39, 0.2, 1)
        local bg = resultFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.07, 0.08, 0.105, 0.96)
        resultFrame.text = resultFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        resultFrame.text:SetPoint("CENTER", 0, 8)
        resultFrame.hint = resultFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        resultFrame.hint:SetPoint("BOTTOM", 0, 10)
        resultFrame.hint:SetText("click to close")
        resultFrame.hint:SetTextColor(0.6, 0.63, 0.68)
        resultFrame:SetScript("OnClick", function(self) self:Hide() end)
    end
    resultFrame.resultText = text
    resultFrame.text:SetText(text)
    resultFrame.text:SetTextColor(color[1], color[2], color[3])
    resultFrame:Show()
    resultToken = resultToken + 1
    local token = resultToken
    if C_Timer and C_Timer.After then
        C_Timer.After(RESULT_SECONDS, function()
            if resultFrame and token == resultToken then resultFrame:Hide() end
        end)
    end
end

local function finish()
    if not vote then return end
    local by = vote.by
    local q, b, total = tally()
    local result, color
    if total == 0 then result, color = "Nobody voted", { 0.6, 0.63, 0.68 }
    elseif q > b then result, color = CHOICES.Q.text, CHOICES.Q.color
    elseif b > q then result, color = CHOICES.B.text, CHOICES.B.color
    else result, color = "A tie", { 0.89, 0.71, 0.29 } end
    showResult(result, color)
    vote = nil
    if frame then frame:Hide() end
    -- the session ends when the vote says bed time: titles are offered (Titles.lua)
    -- Bed time ends the session for everybody (every client ends its own, decision 134). The
    -- listeners (titles) read the values of the session first, then the new one starts.
    if b > q then
        OMQ:Fire("VOTE_END", "bed")
        if OMQ.Measure and OMQ.Measure.ResetSession then pcall(OMQ.Measure.ResetSession, OMQ.Measure) end
    elseif q > b then
        -- "One more quest!" won: whoever started the vote looks for the quest, the arrow goes to all (decision 302)
        OMQ:Fire("VOTE_END", "quest", by)
    end
end

function V:Tick()
    if not vote then return end
    local _, _, total = tally()
    if GetTime() - vote.startAt >= DURATION or total >= participants() then
        finish()
    else
        refresh()
    end
end

-- brings the vote window back (it was closed with the x or Escape)
function V:ShowWindow()
    if vote and frame then frame:Show(); return true end
    return false
end

-- true while a vote runs and I have not voted yet (the minimap icon pulses)
function V:NeedsMyVote()
    if not vote then return false end
    local me = OMQ:GetSelf()
    return not (me and vote.votes[me.guid])
end

-- Starts a vote for the whole group (called by /omq).
function V:Start()
    local me = OMQ:GetSelf()
    if not me then return end
    if not OMQ:GetChannel() then
        -- alone there is nobody to ask: one more quest at once (decision 302)
        if OMQ.NextQuest then OMQ.NextQuest.Press() else OMQ:Print("The vote needs a group.") end
        return
    end
    if vote then
        if frame then frame:Show() end
        return
    end
    local wait = lastStart + COOLDOWN - GetTime()
    if wait > 0 then
        OMQ:Print(string.format("The next vote is possible in %d min.", math.ceil(wait / 60)))
        return
    end
    local id = tostring(time()) .. "-" .. me.guid:sub(-4)
    begin(id, me.guid, me.name, true)
    OMQ:Send("VS", id, me.guid, me.name)
end

function V:Cast(choice)
    local me = OMQ:GetSelf()
    if not (vote and me and CHOICES[choice]) then return end
    vote.votes[me.guid] = choice
    OMQ:Send("VV", vote.id, me.guid, choice)
    self:Tick()
end

local function handleStart(fields)
    local id, guid, name = fields[1], fields[2], fields[3]
    if not (id and guid and guid ~= "") then return end
    local me = OMQ:GetSelf()
    if me and guid == me.guid then return end
    if vote then
        -- two starts at once: the lower id wins on every client
        if id >= vote.id then return end
    elseif (GetTime() - lastStart) < COOLDOWN then
        return
    end
    begin(id, guid, name)
end
OMQ:RegisterMessage("VS", handleStart)

local function handleVote(fields)
    local id, guid, choice = fields[1], fields[2], fields[3]
    if not (vote and id == vote.id and guid and CHOICES[choice]) then return end
    if not OMQ.users[guid] then return end
    vote.votes[guid] = choice
    V:Tick()
end
OMQ:RegisterMessage("VV", handleVote)

OMQ:On("SLASH_EMPTY", function() V:Start() end)
