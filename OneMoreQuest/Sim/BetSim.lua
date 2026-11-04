-- One More Quest: bet simulator (decision 395), /omq bet sim
-- Try every bet alone: one fake dad (Karle, from the dad simulator Sim/Sim.lua) is in the group.
-- While it runs: timed bets last 1 minute, there is no cooldown between bets, Karle always joins and
-- bets against my pick (every bet gets a winner and a loser), and debts to Karle are never mailed.
-- The window lists all 10 bets: I start one (the normal create window opens, ready to send) or Karle
-- starts one (the normal invite window opens). Next to each bet: what my client measures right now,
-- and at the end the values that decided. Buttons make Karle die, land a killing blow and so on.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local BS = {}
OMQ.BetSim = BS

local GREY = "|cff9aa0aa"
local GOLD = "|cffe3b54a"
local GREEN = "|cff7dc770"
local RED = "|cffe0786b"
local ROW_H = 30
local W = 700

local frame
local function B() return OMQ.Bets end
local function UI() return OMQ.BetUI end
local function me() return OMQ:GetSelf() end
local function now() return GetTime() end
local function karle()
    local list = OMQ.Sim and OMQ.Sim:Dads() or {}
    return list[1]
end
local function clock(sec)
    sec = math.max(0, math.floor(sec or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

function BS:Active() return B().TestMode() end

-- start the simulator: one fake dad, test mode
function BS:Start()
    if not OMQ.Sim then return false end
    if not B().TestMode() then
        OMQ.Sim:Start(1)
        OMQ.Sim.betTest = true
        OMQ:Fire("BETS_CHANGED")
    end
    return true
end

function BS:Stop()
    if OMQ.Sim and OMQ.Sim.active then OMQ.Sim:Stop() end
    if frame then frame:Hide() end
end

-- the newest bet of a kind
local function latest(kind)
    for _, b in ipairs(B():List()) do if b.kind == kind then return b end end
end
BS.Latest = latest

local WAIT = {
    death = "die to win",
    kb = "land a killing blow to win",
    near = "drop below 20% health (and live) to win",
    npc = "target an NPC starting with %s",
    player = "target a stranger starting with %s",
}

-- what my client has measured so far for a running bet (the value that counts for me)
function BS.MyValue(b)
    local m = me()
    if not (m and b) then return "" end
    if not b.answers[m.guid] then return "you are not in" end
    local k = B().KIND[b.kind]
    local mine = b.values and b.values[m.guid]
    if mine ~= nil then return "you: " .. UI().FormatValue(b, { value = mine }) .. " (sent)" end
    if k.mode == "first" then
        local w = WAIT[b.kind] or ""
        if k.letter then w = string.format(w, b.letter or "?") end
        return w
    end
    local s = OMQ.Measure and OMQ.Measure.Session and OMQ.Measure:Session() or {}
    if b.kind == "run" then
        return string.format("you: %.0f yd so far", math.max(0, (s.yards or 0) - (b.base and b.base.yards or 0)))
    elseif b.kind == "loot" then
        return "you: " .. B().Money(b.looted or 0) .. " looted so far"
    elseif b.kind == "fall" then
        if b.fellDead or (b.bestFall or 0) < 0 then return "you: died from a fall (out)" end
        if b.pendingFall then
            return "you: " .. UI().FormatValue(b, { value = b.pendingFall.amount }) .. " (counts in a moment if you live)"
        end
        return "you: best fall so far " .. UI().FormatValue(b, { value = b.bestFall or 0 })
    elseif b.kind == "dmg" then
        if b.fightEndAt then return "you: fight over, your damage is sent in a few seconds" end
        if b.fightBase then return "you: fighting..." end
        return "start a fight to win"
    elseif b.kind == "roll" then
        return "rolling..."
    end
    return ""
end

-- one status line for the newest bet of a kind
function BS.Status(kind)
    local b = latest(kind)
    if not b then return GREY .. "not tried yet|r" end
    local m = me()
    if b.state == "join" then
        local kd = karle()
        local karleIn = kd and b.answers[kd.guid] ~= nil
        return string.format("%sjoining %ds|r - Karle %s", GOLD, math.max(0, math.ceil(b.joinUntil - now())),
            karleIn and "is in" or "thinks...")
    elseif b.state == "active" then
        local left = b.endsAt and (clock(b.endsAt - now()) .. " left") or "running"
        return GOLD .. left .. "|r - " .. BS.MyValue(b)
    end
    -- done or off: did I win, and the values that decided
    local net = 0
    for _, p in ipairs(b.pays or {}) do
        if m and p.to == m.guid then net = net + p.amount elseif m and p.from == m.guid then net = net - p.amount end
    end
    local head
    if b.state == "done" then
        if net > 0 then head = GREEN .. "you won +" .. B().Money(net) .. "|r"
        elseif net < 0 then head = RED .. "you lost -" .. B().Money(-net) .. "|r"
        else head = "done" end
    else
        head = GREY .. "off: " .. (b.reason or "no result") .. "|r"
    end
    local values = UI().ValuesLine(b)
    return head .. (values and (" - " .. values) or "")
end

----------------------------------------------------------------------
-- The window
----------------------------------------------------------------------
local function startMine(kind)
    local m = me()
    if not m then return end
    local ok, why = B():CanStart(kind)
    if not ok then frame.note:SetText(RED .. why .. "|r"); return end
    UI():OpenCreate(kind, m.guid, 100)
end

local function startKarle(kind)
    local d = karle()
    if not d then return end
    local ok, why = OMQ.Sim:StartBet(d, kind)
    if not ok then frame.note:SetText(RED .. tostring(why) .. "|r") end
end

local function endNow(kind)
    local b = latest(kind)
    if not (b and b.state == "active") then return end
    if b.endsAt then b.endsAt = now()
    elseif b.kind == "dmg" then b.decideAt = now() end      -- no fight yet: decide with what is there
end
BS.EndNow = endNow

local function build()
    local U = UI()
    local n = #B().KINDS
    frame = U.Panel("OneMoreQuestBetSim", W, 74 + n * ROW_H + 96)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -90)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.title:SetText("Bet Simulator")
    frame.sub:SetText("fake dad: Karle - timed bets run 1 minute")
    local head = U.Text(frame, "GameFontHighlightSmall")
    head:SetPoint("TOPLEFT", 14, -40); head:SetWidth(W - 28)
    head:SetText(GREY .. "Start a bet yourself or let Karle start it. Karle always bets against you. " ..
        "Your own measurement is shown live; at the end you see the values that decided.|r")
    frame.rows = {}
    for i, k in ipairs(B().KINDS) do
        local y = -64 - (i - 1) * ROW_H
        local r = {}
        r.name = U.Text(frame, "GameFontHighlight")
        r.name:SetPoint("TOPLEFT", 14, y - 4); r.name:SetWidth(186)
        r.name:SetText(k.name)
        r.mine = U.Button(frame, 62, ROW_H - 4, "I start", function() startMine(k.id) end)
        r.mine:SetPoint("TOPLEFT", 204, y)
        r.karle = U.Button(frame, 82, ROW_H - 4, "Karle starts", function() startKarle(k.id) end)
        r.karle:SetPoint("TOPLEFT", 270, y)
        r.stop = U.Button(frame, 42, ROW_H - 4, "End", function() endNow(k.id) end)
        r.stop:SetPoint("TOPLEFT", 356, y)
        r.status = U.Text(frame, "GameFontHighlightSmall")
        r.status:SetPoint("TOPLEFT", 404, y - 2); r.status:SetWidth(W - 404 - 12)
        r.status:SetHeight(ROW_H - 2); r.status:SetJustifyV("TOP"); r.status:SetWordWrap(true)
        r.kind = k.id
        frame.rows[i] = r
    end
    local y = -64 - n * ROW_H - 8
    local lbl = U.Text(frame, "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 14, y - 6); lbl:SetText("KARLE:")
    local acts = {
        { "dies", "die" }, { "killing blow", "kb" }, { "near death", "near" }, { "finds the letter", "target" },
        { "fight damage", "fight" },
    }
    local x = 70
    frame.acts = {}
    for _, a in ipairs(acts) do
        local w = 18 + #a[1] * 7
        local btn = U.Button(frame, w, 22, a[1], function()
            local d = karle()
            if not d then return end
            if a[2] == "fight" then OMQ:RunCommand("sim", "fight")
            elseif not OMQ.Sim:Event(d, a[2]) then frame.note:SetText(GREY .. "No running bet for that.|r") end
        end)
        btn:SetPoint("TOPLEFT", x, y)
        x = x + w + 6
        frame.acts[#frame.acts + 1] = btn
    end
    frame.note = U.Text(frame, "GameFontHighlightSmall")
    frame.note:SetPoint("TOPLEFT", 14, y - 32); frame.note:SetWidth(W - 28 - 140)
    frame.foot = U.Text(frame, "GameFontHighlightSmall")
    frame.foot:SetPoint("TOPLEFT", 14, y - 50); frame.foot:SetWidth(W - 28 - 140)
    frame.foot:SetText(GREY .. "Debts with Karle are never mailed and vanish when the simulator ends. " ..
        "While it runs, addon messages go to Karle only.|r")
    frame.off = U.Button(frame, 130, 28, "End simulator", function() BS:Stop() end)
    frame.off:SetPoint("BOTTOMRIGHT", -14, 12)
    local t = 0
    frame:SetScript("OnUpdate", function(_, e)
        t = t + (e or 0)
        if t < 0.5 then return end
        t = 0
        BS:Refresh()
    end)
end

function BS:Refresh()
    if not (frame and frame:IsShown()) then return end
    if not B().TestMode() then frame:Hide(); return end
    local running = B():Running()
    for _, r in ipairs(frame.rows) do
        local b = latest(r.kind)
        local busy = b and (b.state == "join" or b.state == "active")
        local can = B():CanStart(r.kind)
        r.mine:SetEnabledLook(can)
        r.karle:SetEnabledLook(can)
        r.stop:SetEnabledLook(busy and b.state == "active" and (b.endsAt ~= nil or b.kind == "dmg"))
        r.status:SetText(BS.Status(r.kind))
    end
    if #running >= B().MAX_RUNNING then
        frame.note:SetText(GREY .. "Three bets are running: wait for one to end (or press End).|r")
    end
end

function BS:Frame() return frame end

function BS:Toggle()
    if OMQ.Unlock and not OMQ.Unlock:Has("bets") then OMQ:Print("Bets open at level 5."); return end
    if frame and frame:IsShown() then frame:Hide(); return end
    if not self:Start() then return end
    if not frame then build() end
    frame.note:SetText("")
    frame:Show()
    self:Refresh()
end

OMQ:On("BETS_CHANGED", function() BS:Refresh() end)
