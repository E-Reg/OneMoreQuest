-- One More Quest: titles (decision 133, the "Session awards" idea in a first form)
-- When a vote ends with "Bed time", every dad is offered three titles that fit the values of
-- the session that is ending, each with the reason. The pick is saved per character and is
-- worn until the next session ends with a bed time vote (across all sessions in between).
-- The title is shown in the statistics tooltip under the name. Above the offers the picker shows the
-- evening in numbers for the whole group (decision 201).
--   TI|proto|guid|title      (own title, sent when it changes and when somebody joins)
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local MAX_TITLE = 24           -- bytes accepted from other players
local OFFERS = 3
local SHOW_DELAY = 1.5         -- seconds after the vote result

local T = {}
OMQ.Titles = T

local F = function() return OMQ.Ranking and OMQ.Ranking.formats or {} end

local function num(v) return type(v) == "number" and v == v and v or nil end
local function fmt(name, v) local f = F()[name]; return f and f(v) or tostring(v) end

----------------------------------------------------------------------
-- The catalog. test(v) returns a score (1 = just enough) or nil, plus the reason.
-- Every title is meant to be funny or cool; none says that somebody was bad.
----------------------------------------------------------------------
local function atLeast(key, minimum, text, name)
    return function(v)
        local x = num(v[key])
        if x and x >= minimum then return x / minimum, string.format(text, fmt(name or "int", x)) end
    end
end

local CATALOG = {
    { id = "wanderer",   text = "the Wanderer",      test = atLeast("yards", 3000, "Walked %s yards", "compact") },
    { id = "marathon",   text = "the Marathoner",    test = atLeast("ptime", 5400, "Played %s in one session", "duration") },
    { id = "untouch",    text = "the Untouchable",   test = function(v)
        local d, t = num(v.deaths), num(v.ptime)
        if d == 0 and t and t >= 1800 then return 1 + t / 3600, "No death in " .. fmt("duration", t) end
    end },
    { id = "phoenix",    text = "the Phoenix",       test = atLeast("deaths", 3, "Rose from the dead %s times") },
    { id = "gravity",    text = "Gravity's Friend",  test = function(v)
        local d, x = num(v.falld), num(v.fallx)
        if d and d >= 1 then return 2 + d, string.format("Lost %d fights with gravity", d) end
        if x and x >= 1000 then return x / 1000, "Took " .. fmt("compact", x) .. " fall damage" end
    end },
    { id = "lava",       text = "the Hot Foot",      test = atLeast("lava", 1, "Took a lava bath %s times") },
    { id = "deepdiver",  text = "the Deep Diver",    test = atLeast("drownd", 1, "Forgot to breathe %s times") },
    { id = "teeth",      text = "Skin of Teeth",     test = atLeast("near", 3, "Dropped below 20%% health %s times") },
    { id = "finisher",   text = "Last-Hit Legend",   test = atLeast("kb", 15, "%s killing blows") },
    { id = "questy",     text = "Quest Machine",     test = atLeast("quests", 4, "%s quests handed in") },
    { id = "learner",    text = "Fast Learner",      test = atLeast("xph", 3000, "%s XP per hour", "compact") },
    { id = "explorer",   text = "the Explorer",      test = atLeast("xpdisc", 500, "%s XP from discovering places", "compact") },
    { id = "digger",     text = "Gold Digger",       test = atLeast("gold", 30000, "Earned %s", "gold") },
    { id = "auctioneer", text = "the Auctioneer",    test = atLeast("aucp", 3, "Posted %s auctions") },
    { id = "bargain",    text = "Bargain Hunter",    test = atLeast("aucb", 3, "Bought %s auctions") },
    { id = "greedy",     text = "Greed is Good",     test = atLeast("greed", 3, "%s greed rolls") },
    { id = "needy",      text = "Needs It More",     test = atLeast("need", 3, "%s need rolls") },
    { id = "heavy",      text = "Heavy Hitter",      test = atLeast("hit", 150, "Biggest hit: %s", "compact") },
    { id = "lifeline",   text = "the Lifeline",      test = atLeast("heal", 150, "Biggest heal: %s", "compact") },
    { id = "spear",      text = "the Spearhead",     test = atLeast("dmg", 40, "%s of the group's damage", "percent") },
    { id = "instigator", text = "the Instigator",    test = atLeast("fights", 8, "Started %s fights") },
    { id = "wellfed",    text = "Well Fed",          test = atLeast("food", 50, "Food buff up %s of the time", "percent") },
    { id = "climber",    text = "Level Climber",     test = function(v)
        local x = num(v.lvlp)
        if x and x >= 1 then return x, string.format("Gained %.1f levels", x) end
    end },
}

-- neutral, cool titles when the session offers too little
local FALLBACK = {
    { id = "dependable", text = "the Dependable",  reason = "You showed up and played" },
    { id = "steady",     text = "the Steady Hand", reason = "Kept calm and carried on" },
    { id = "onemore",    text = "Just One More",   reason = "Always one more quest" },
}

----------------------------------------------------------------------
-- Offers from the values of the session
----------------------------------------------------------------------
function T:MakeOffers(values, currentId)
    local found = {}
    for _, c in ipairs(CATALOG) do
        local ok, score, reason = pcall(c.test, values)
        if ok and score and c.id ~= currentId then
            found[#found + 1] = { id = c.id, text = c.text, reason = reason, score = math.min(score, 6) }
        end
    end
    table.sort(found, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.id < b.id
    end)
    local out = {}
    for _, o in ipairs(found) do
        if #out < OFFERS then out[#out + 1] = { id = o.id, text = o.text, reason = o.reason } end
    end
    for _, f in ipairs(FALLBACK) do
        if #out < OFFERS and f.id ~= currentId then out[#out + 1] = { id = f.id, text = f.text, reason = f.reason } end
    end
    return out
end

----------------------------------------------------------------------
-- The saved title
----------------------------------------------------------------------
local function store()
    if not OMQDB then return {} end
    OMQDB.titles = OMQDB.titles or {}
    return OMQDB.titles
end

function T:Mine()
    local guid = UnitGUID("player")
    return guid and store()[guid] or nil
end

-- Title text of a player in the group (own: saved, others: received).
function T:Get(guid)
    local me = OMQ:GetSelf()
    if me and guid == me.guid then
        local t = T:Mine()
        return t and t.text
    end
    local u = OMQ.users and OMQ.users[guid]
    return u and u.title
end

local function clean(text)
    text = tostring(text or ""):gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > MAX_TITLE then text = text:sub(1, MAX_TITLE) end
    return text
end

function T:SendMine()
    local me = OMQ:GetSelf()
    local t = T:Mine()
    if me and t and OMQ:GetChannel() then OMQ:Send("TI", me.guid, t.text) end
end

function T:Pick(offer)
    local guid = UnitGUID("player")
    if not (guid and offer) then return end
    store()[guid] = { id = offer.id, text = offer.text, reason = offer.reason, at = time() }
    T.pending = nil
    T:SendMine()
    OMQ:Fire("TITLE_CHANGED", guid)
end

OMQ:RegisterMessage("TI", function(f)
    local guid, text = f[1], clean(f[2])
    local me = OMQ:GetSelf()
    if not guid or guid == "" or (me and guid == me.guid) then return end
    local u = OMQ.users[guid]
    if not u then return end
    u.title = text ~= "" and text or nil
    OMQ:Fire("TITLE_CHANGED", guid)
end)

OMQ:On("USER_JOINED", function() T:SendMine() end)

----------------------------------------------------------------------
-- The evening in numbers (decision 201), shown above the titles
----------------------------------------------------------------------
T.SUMMARY_COLS = {
    { key = "lvlp",    head = "Levels", fmt = "plus2" },
    { key = "quests",  head = "Quests", fmt = "int" },
    { key = "gold",    head = "Gold",   fmt = "gold" },
    { key = "deaths",  head = "Deaths", fmt = "int" },
    { key = "gamble",  head = "Bets",   fmt = "goldsigned" },
}

-- me first, then the dads in the group with their shared values; the sums for "Together"
function T:MakeSummary(myValues)
    local rows = {}
    local me = OMQ:GetSelf()
    rows[1] = { name = me and me.name or "You", class = me and me.class, values = myValues or {}, isSelf = true }
    local others = {}
    for guid, u in pairs(OMQ.users or {}) do
        if (not me or guid ~= me.guid) and OMQ:IsOnline(u) and u.values then
            others[#others + 1] = { name = u.name or "?", class = u.class, values = u.values }
        end
    end
    table.sort(others, function(a, b) return a.name < b.name end)
    for _, o in ipairs(others) do if #rows < 5 then rows[#rows + 1] = o end end
    local total = {}
    for _, c in ipairs(T.SUMMARY_COLS) do
        local sum, any = 0, false
        for _, r in ipairs(rows) do
            local v = num(r.values[c.key])
            if v then sum = sum + v; any = true end
        end
        total[c.key] = any and sum or nil
    end
    return { rows = rows, total = total, ptime = num((myValues or {}).ptime) }
end

function T.Cell(key, v)
    if v == nil then return "-" end
    for _, c in ipairs(T.SUMMARY_COLS) do
        if c.key == key then return fmt(c.fmt, v) end
    end
    return tostring(v)
end

----------------------------------------------------------------------
-- The picker
----------------------------------------------------------------------
local frame, rows

local function buildFrame()
    frame = CreateFrame("Frame", "OneMoreQuestTitlePicker", UIParent)
    frame:SetSize(480, 66 + OFFERS * 58)
    frame:SetFrameStrata("DIALOG")
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    local border = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    border:SetPoint("TOPLEFT", -1, 1); border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.48, 0.39, 0.2, 1)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.07, 0.08, 0.105, 1)
    -- the evening (decision 201): a small table above the titles
    frame.sumHead = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.sumHead:SetPoint("TOP", 0, -12)
    frame.sumHead:SetTextColor(0.89, 0.71, 0.29)
    frame.cells = {}
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOP", 0, -12)
    frame.title:SetTextColor(0.89, 0.71, 0.29)
    frame.title:SetText("Pick your title for the next session")
    frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.sub:SetPoint("TOP", 0, -34)
    frame.sub:SetTextColor(0.6, 0.63, 0.68)
    rows = {}
    for i = 1, OFFERS do
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(456, 52)
        b:SetPoint("TOPLEFT", 12, -52 - (i - 1) * 58)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(0.12, 0.13, 0.17, 1)
        b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        b.name:SetPoint("TOPLEFT", 12, -8)
        b.name:SetTextColor(0.93, 0.92, 0.89)
        b.reason = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.reason:SetPoint("TOPLEFT", 12, -30)
        b.reason:SetTextColor(0.6, 0.63, 0.68)
        b:SetScript("OnClick", function(self)
            if self.offer then T:Pick(self.offer) end
            frame:Hide()
        end)
        b:SetScript("OnEnter", function(self) self.bg:SetColorTexture(0.2, 0.2, 0.26, 1) end)
        b:SetScript("OnLeave", function(self) self.bg:SetColorTexture(0.12, 0.13, 0.17, 1) end)
        rows[i] = b
    end
    local skip = CreateFrame("Button", nil, frame)
    skip:SetSize(24, 24)
    skip:SetPoint("TOPRIGHT", -4, -4)
    local x = skip:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    x:SetPoint("CENTER"); x:SetText("x"); x:SetTextColor(0.55, 0.58, 0.63)
    skip:SetScript("OnClick", function() frame:Hide() end)       -- closing keeps the current title
    frame:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestTitlePicker") end
end

local NAME_W, COL_W, ROW_H = 120, 64, 16

local function cell(i)
    if not frame.cells[i] then
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        frame.cells[i] = fs
    end
    frame.cells[i]:Show()
    return frame.cells[i]
end

local function classHex(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return string.format("%02x%02x%02x", math.floor(c.r * 255 + .5), math.floor(c.g * 255 + .5), math.floor(c.b * 255 + .5)) end
    return "ededE3"
end

-- draws the summary table from y downwards, returns the new y
local function drawSummary(sum, y)
    for _, c in ipairs(frame.cells) do c:Hide() end
    if not sum or not sum.rows or #sum.rows == 0 then frame.sumHead:Hide(); return y end
    frame.sumHead:Show()
    frame.sumHead:ClearAllPoints(); frame.sumHead:SetPoint("TOP", 0, y)
    frame.sumHead:SetText("Tonight" .. (sum.ptime and ("  |cff9aa0a6" .. fmt("duration", sum.ptime) .. "|r") or ""))
    y = y - 26
    local n = 0
    local function put(text, x, yy, justify, color)
        n = n + 1
        local fs = cell(n)
        fs:ClearAllPoints()
        fs:SetWidth(justify == "LEFT" and NAME_W or COL_W)
        fs:SetJustifyH(justify)
        fs:SetPoint("TOPLEFT", x, yy)
        fs:SetText(text)
        local c = color or { 0.93, 0.92, 0.89 }
        fs:SetTextColor(c[1], c[2], c[3])
    end
    local x0 = 16
    local grey = { 0.6, 0.63, 0.68 }
    put("", x0, y, "LEFT", grey)
    for i, c in ipairs(T.SUMMARY_COLS) do put(c.head, x0 + NAME_W + (i - 1) * COL_W, y, "RIGHT", grey) end
    y = y - ROW_H
    for _, r in ipairs(sum.rows) do
        put("|cff" .. classHex(r.class) .. r.name .. "|r", x0, y, "LEFT")
        for i, c in ipairs(T.SUMMARY_COLS) do put(T.Cell(c.key, r.values[c.key]), x0 + NAME_W + (i - 1) * COL_W, y, "RIGHT") end
        y = y - ROW_H
    end
    if #sum.rows > 1 then
        local gold = { 0.89, 0.71, 0.29 }
        put("Together", x0, y - 2, "LEFT", gold)
        for i, c in ipairs(T.SUMMARY_COLS) do put(T.Cell(c.key, sum.total[c.key]), x0 + NAME_W + (i - 1) * COL_W, y - 2, "RIGHT", gold) end
        y = y - ROW_H - 2
    end
    return y - 14
end

function T:ShowPicker()
    if not T.pending or #T.pending == 0 then return false end
    if not frame then buildFrame() end
    local cur = T:Mine()
    local y = drawSummary(T.summary, -12)
    frame.title:ClearAllPoints(); frame.title:SetPoint("TOP", 0, y)
    frame.sub:ClearAllPoints(); frame.sub:SetPoint("TOP", 0, y - 22)
    frame.sub:SetText(cur and ("Now: " .. cur.text .. " - closing keeps it") or "Closing the window keeps things as they are")
    local top = y - 40
    for i = 1, OFFERS do
        local o, b = T.pending[i], rows[i]
        b.offer = o
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", 12, top - (i - 1) * 58)
        if o then
            b.name:SetText(o.text)
            b.reason:SetText(o.reason or "")
            b:Show()
        else
            b:Hide()
        end
    end
    frame:SetHeight(-(top - OFFERS * 58) + 6)
    frame:Show()
    return true
end

----------------------------------------------------------------------
-- Trigger: a vote that ended with "Bed time" (the session ends for everybody, Vote.lua)
----------------------------------------------------------------------
-- The offers are made at once from the values of the ending session (Vote.lua starts the
-- new session right after the event); the picker follows a moment later.
OMQ:On("VOTE_END", function(result)
    if result ~= "bed" then return end
    local ok, values = pcall(function() return OMQ.Measure and OMQ.Measure:GetValues() or {} end)
    local cur = T:Mine()
    T.pending = T:MakeOffers(ok and values or {}, cur and cur.id)
    local ok2, sum = pcall(T.MakeSummary, T, ok and values or {})
    T.summary = ok2 and sum or nil
    if C_Timer and C_Timer.After then
        C_Timer.After(SHOW_DELAY, function() pcall(T.ShowPicker, T) end)
    else
        pcall(T.ShowPicker, T)
    end
end)

OMQ:RegisterCommand("title", function(arg)
    if arg == "pick" then
        if not T:ShowPicker() then OMQ:Print("No titles on offer. They come after a vote that ends with Bed time.") end
        return
    elseif arg == "clear" then
        local guid = UnitGUID("player")
        if guid then store()[guid] = nil end
        T:SendMine()
        OMQ:Print("title removed")
        OMQ:Fire("TITLE_CHANGED", guid)
        return
    end
    local t = T:Mine()
    if t then OMQ:Print("your title: " .. t.text .. " (" .. tostring(t.reason or "") .. ")")
    else OMQ:Print("you have no title yet. After a Bed time vote you can pick one.") end
    print("  /omq title pick | clear")
end, "your title; pick from the offers after a Bed time vote")
