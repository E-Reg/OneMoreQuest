-- One More Quest: ledger window, new-card toast, showing a card to the group and the counter
-- Reads Stats/Ledger.lua. The window opens from the quick options once the first tab is open.
-- A shown card flies out of the minimap icon on the other clients; a dad who owns it can counter it
-- with a left click, and only then the one who showed it rests for 5 minutes.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local U = {}
OMQ.LedgerUI = U
U.TAB_MIN = 110    -- narrowest tab column
local L = OMQ.Ledger

local COLS, ROWS = 5, 2
local CW, CH, GAP, PAD = 128, 180, 10, 20
local TOAST_HOLD, INTRO_HOLD, FLEX_HOLD, COUNTER_HOLD = 4, 8, 8, 5
local REST = 300
local MAX_TOASTS = 6

local QCOLOR = { [0] = { .62, .62, .62 }, { 1, 1, 1 }, { .12, 1, 0 }, { 0, .44, .87 }, { .64, .21, .93 }, { 1, .5, 0 } }
local QNAME = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }
local GOLD = { .91, .78, .4 }

local function qcolor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if type(c) == "table" and c.r then return c.r, c.g, c.b end
    local t = QCOLOR[q] or QCOLOR[1]
    return t[1], t[2], t[3]
end
local function hex(r, g, b) return string.format("ff%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)) end
local function colored(text, r, g, b) return "|c" .. hex(r, g, b) .. text .. "|r" end
local dateFn = date or (os and os.date)
local function day(t) return t and dateFn and dateFn("%d.%m.", t) or "" end
local function mmss(s) s = math.max(0, math.floor(s)); return string.format("%d:%02d", math.floor(s / 60), s % 60) end
local function tabName(id) for _, t in ipairs(L.TABS) do if t.id == id then return t.name end end return id end

----------------------------------------------------------------------
-- A card: three faces (face down, seen, owned)
----------------------------------------------------------------------
local function tex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer)
    if r then t:SetColorTexture(r, g, b, a or 1) end
    return t
end

local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil
local TITLE_FONT, BODY_FONT = "Fonts\\MORPHEUS.TTF", "Fonts\\FRIZQT__.TTF"
local EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"

local function font(fs, file, size, plain)
    if fs.SetFont then pcall(fs.SetFont, fs, file, size, "") end
    if plain and fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
    return fs
end

local function newCard(parent, w, h)
    local f = CreateFrame("Button", nil, parent, BACKDROP)
    f:SetSize(w, h)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local big = w >= 180
    local e = big and 7 or 6
    -- rounded edge in the quality color around a plain face
    f.round = f.SetBackdrop and true or false
    if f.round then
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = EDGE, edgeSize = big and 24 or 20,
                        insets = { left = e - 2, right = e - 2, top = e - 2, bottom = e - 2 } })
    end
    -- a second, thin line in the quality color just inside the rounded edge
    f.inner = CreateFrame("Frame", nil, f, BACKDROP)
    f.inner:SetPoint("TOPLEFT", e - 1, -(e - 1)); f.inner:SetPoint("BOTTOMRIGHT", -(e - 1), e - 1)
    if f.inner.SetBackdrop then f.inner:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 }) end
    f.bg = tex(f, "BACKGROUND")
    f.bg:SetPoint("TOPLEFT", e - 1, -(e - 1)); f.bg:SetPoint("BOTTOMRIGHT", -(e - 1), e - 1)
    if f.round then f.bg:Hide() end
    local m = e + 5
    local artH = math.floor(h * 0.36)
    f.art = tex(f, "ARTWORK")
    f.art:SetPoint("TOPLEFT", m, -m); f.art:SetPoint("TOPRIGHT", -m, -m); f.art:SetHeight(artH)
    -- a small rounded frame over the art box (above the 3D model)
    f.artEdge = CreateFrame("Frame", nil, f, BACKDROP)
    f.artEdge:SetPoint("TOPLEFT", f.art, "TOPLEFT", -3, 3); f.artEdge:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT", 3, -3)
    f.artEdge:SetFrameLevel((f:GetFrameLevel() or 0) + 5)
    if f.artEdge.SetBackdrop then f.artEdge:SetBackdrop({ edgeFile = EDGE, edgeSize = 10 }) end
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetSize(math.floor(artH * 0.7), math.floor(artH * 0.7))
    f.icon:SetPoint("CENTER", f.art, "CENTER")
    f.artH, f.e, f.m = artH, e, m
    local inner = w - 2 * m
    f.title = font(f:CreateFontString(nil, "OVERLAY", big and "GameFontNormalLarge" or "GameFontNormal"), TITLE_FONT, big and 19 or 15, true)
    f.title:SetPoint("TOP", f.art, "BOTTOM", 0, -8); f.title:SetWidth(inner)
    f.title:SetJustifyH("CENTER")
    f.line = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, big and 12 or 10, true)
    f.line:SetPoint("TOP", f.title, "BOTTOM", 0, -4); f.line:SetWidth(inner)
    f.line:SetJustifyH("CENTER")
    if f.line.SetSpacing then f.line:SetSpacing(2) end
    -- bottom: tier pips or progress bar, then a thin rule, then date / level left and number right
    f.rule = tex(f, "OVERLAY")
    f.rule:SetPoint("BOTTOMLEFT", m, e + 19); f.rule:SetPoint("BOTTOMRIGHT", -m, e + 19); f.rule:SetHeight(1)
    f.pips = {}
    for i = 1, 4 do
        local p = tex(f, "OVERLAY")
        p:SetSize(7, 7)
        f.pips[i] = p
    end
    f.extra = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, big and 11 or 9, true)
    f.extra:SetPoint("BOTTOM", f, "BOTTOM", 0, e + 37); f.extra:SetWidth(inner)
    f.extra:SetJustifyH("CENTER")
    f.footL = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, big and 11 or 9, true)
    f.footL:SetPoint("BOTTOMLEFT", m, e + 6)
    f.footR = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, big and 11 or 9, true)
    f.footR:SetPoint("BOTTOMRIGHT", -m, e + 6)
    f.barBg = tex(f, "OVERLAY", .55, .54, .51, 1)
    f.barBg:SetPoint("BOTTOMLEFT", m + 6, e + 26); f.barBg:SetPoint("BOTTOMRIGHT", -(m + 6), e + 26); f.barBg:SetHeight(5)
    f.bar = tex(f, "OVERLAY", .24, .23, .21, 1)
    f.bar:SetPoint("TOPLEFT", f.barBg, "TOPLEFT"); f.bar:SetHeight(5)
    f.back = f:CreateTexture(nil, "OVERLAY")
    f.back:SetSize(math.floor(w * 0.45), math.floor(w * 0.45))
    f.back:SetPoint("CENTER", 0, 10)
    f.backNum = font(f:CreateFontString(nil, "OVERLAY", "GameFontNormal"), TITLE_FONT, big and 18 or 14)
    f.backNum:SetPoint("TOP", f.back, "BOTTOM", 0, -10)
    f.w, f.h = w, h
    f.model, f.card, f.state, f.hover, f.leaving = false, false, false, false, false
    return f
end

local function setBg(f, r, g, b)
    if f.round then f:SetBackdropColor(r, g, b, 1) else f.bg:SetColorTexture(r, g, b, 1) end
end
local function setEdge(f, r, g, b)
    if f.round then f:SetBackdropBorderColor(r, g, b, 1) end
    if f.inner.SetBackdropBorderColor then f.inner:SetBackdropBorderColor(r, g, b, .75) end
end
local function setArtEdge(f, r, g, b, a)
    if f.artEdge.SetBackdropBorderColor then f.artEdge:SetBackdropBorderColor(r, g, b, a or 1) end
end
-- n pips centered on the card, just above the rule
local function placePips(f, n)
    local step = 11
    local x0 = -((n - 1) * step) / 2
    for i = 1, n do
        local p = f.pips[i]
        p:ClearAllPoints()
        p:SetPoint("CENTER", f, "BOTTOM", x0 + (i - 1) * step, f.e + 28)
    end
end
local function showAll(f, list, on) for _, k in ipairs(list) do if on then f[k]:Show() else f[k]:Hide() end end end
local FACE = { "art", "artEdge", "icon", "title", "line", "extra", "footL", "footR", "rule" }

local function setModel(f, c, on)
    if f.model then f.model:Hide() end
    if not (on and c.npc) then return false end
    if not f.model then
        f.model = CreateFrame("PlayerModel", nil, f)
        f.model:SetPoint("TOPLEFT", f.art, "TOPLEFT"); f.model:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT")
    end
    if not f.model.SetCreature then return false end
    local fine = pcall(f.model.SetCreature, f.model, c.npc)
    if fine then f.model:Show() end
    return fine
end

-- state: "down", "seen" or "own"; num: "03 / 13"
local function paint(f, c, state, num, rec, value)
    f.card, f.state = c, state
    for _, p in ipairs(f.pips) do p:Hide() end
    f.barBg:Hide(); f.bar:Hide()
    if state == "down" then
        showAll(f, FACE, false)
        if f.model then f.model:Hide() end
        setBg(f, .16, .13, .09)
        setEdge(f, .45, .36, .2)
        f.back:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        f.back:SetDesaturated(true); f.back:SetAlpha(.35)
        f.back:Show(); f.backNum:Show()
        f.backNum:SetText(num or ""); f.backNum:SetTextColor(.63, .54, .35)
        return
    end
    f.back:Hide(); f.backNum:Hide()
    showAll(f, FACE, true)
    f.icon:SetTexture(c.icon)
    f.title:SetText(c.title)
    f.footR:SetText("")
    if state == "seen" then
        local seen = L:Seen(c.id) or {}
        setBg(f, .78, .76, .72)
        setEdge(f, .62, .62, .62)
        f.art:SetColorTexture(.36, .35, .33, 1)
        setArtEdge(f, .5, .49, .46)
        f.rule:SetColorTexture(.45, .44, .41, .6)
        f.icon:SetDesaturated(true); f.icon:Show()
        setModel(f, c, false)
        f.title:SetTextColor(.18, .17, .15)
        f.line:SetText(L:Goal(c, 1)); f.line:SetTextColor(.18, .17, .15)
        local need = L:Need(c, 1)
        local v = math.min(value or 0, need)
        f.barBg:Show()
        if v > 0 then f.bar:Show(); f.bar:SetWidth(math.max(1, (f.w - 2 * (f.m + 6)) * v / need)) end
        f.extra:SetText(math.floor(v) .. " / " .. need); f.extra:SetTextColor(.18, .17, .15)
        f.footL:SetText("Seen: " .. tostring(seen.by or "?")); f.footL:SetTextColor(.18, .17, .15)
        f.footR:SetTextColor(.18, .17, .15)
        return
    end
    rec = rec or {}
    local q = L:Quality(c, rec.n)
    local r, g, b = qcolor(q)
    setBg(f, .94, .89, .78)
    setEdge(f, r, g, b)
    f.art:SetColorTexture(.11, .09, .06, 1)
    setArtEdge(f, .55, .43, .2)
    f.rule:SetColorTexture(.55, .43, .2, .5)
    f.icon:SetDesaturated(false)
    if setModel(f, c, true) then f.icon:Hide() else f.icon:Show() end
    f.title:SetTextColor(.17, .11, .05)
    local line = L:Goal(c, rec.n)
    if rec.x then line = line .. " (" .. rec.x .. ")" end
    f.line:SetText(line); f.line:SetTextColor(.17, .11, .05)
    if c.tiers then
        placePips(f, #c.tiers)
        for i = 1, #c.tiers do
            local p = f.pips[i]
            p:Show()
            if i <= (rec.n or 0) then p:SetColorTexture(r, g, b, 1) else p:SetColorTexture(.85, .8, .69, 1) end
        end
    end
    f.footL:SetText(day(rec.t)); f.footL:SetTextColor(.35, .27, .13)
    f.footR:SetText(rec.l and ("Level " .. rec.l) or "")
    f.footR:SetTextColor(.35, .27, .13)
    f.extra:SetText(rec.g and rec.g ~= "" and ("With " .. rec.g) or ""); f.extra:SetTextColor(.24, .17, .09)
end

-- the tooltip of a card; hint: the last line (what a click does)
local function tooltip(owner, c, hint, flexedBy)
    if not (GameTooltip and c) then return end
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    local rec = L:Owned(c.id)
    local seen = L:Seen(c.id)
    local tier = rec and rec.n or (seen and seen.n) or 1
    local q = L:Quality(c, tier)
    local r, g, b = qcolor(q)
    GameTooltip:AddLine(c.title, r, g, b)
    GameTooltip:AddLine(tabName(c.tab) .. (c.tiers and " - tier card" or ""), 1, 1, 1)
    GameTooltip:AddLine(QNAME[q] .. (c.tiers and (", tier " .. tier .. " of " .. #c.tiers) or ""), 1, .82, 0)
    GameTooltip:AddLine(L:Goal(c, tier), 1, 1, 1, true)
    if c.tiers then
        local parts = {}
        for i, n in ipairs(c.tiers) do parts[#parts + 1] = QNAME[L:Quality(c, i)] .. " " .. n end
        GameTooltip:AddLine(table.concat(parts, " - "), .8, .8, .8, true)
    end
    local res = L:Evaluate()
    local v = res and res[c.id] and res[c.id].v or 0
    if rec then
        GameTooltip:AddLine("You have this card.", .12, 1, 0)
        if c.tiers and rec.n < #c.tiers then
            GameTooltip:AddLine("Progress: " .. math.floor(v) .. " / " .. L:Need(c, rec.n + 1), .12, 1, 0)
        end
    else
        GameTooltip:AddLine("You do not have this card yet.", 1, .42, .42)
        GameTooltip:AddLine("Progress: " .. math.floor(math.min(v, L:Need(c, 1))) .. " / " .. L:Need(c, 1), .8, .8, .8)
    end
    if flexedBy then GameTooltip:AddLine("Shown by " .. flexedBy, .8, .8, .8)
    elseif seen and seen.by then GameTooltip:AddLine("Seen with " .. seen.by, .8, .8, .8) end
    if hint then GameTooltip:AddLine(hint, 1, .82, 0) end
    GameTooltip:Show()
end
U._Tooltip = tooltip

----------------------------------------------------------------------
-- Small animations (OnUpdate, so they run on every client version)
----------------------------------------------------------------------
local function animate(f, dur, step, done)
    local t = 0
    f:SetScript("OnUpdate", function(self, dt)
        t = t + dt
        local p = math.min(1, t / dur)
        step(p)
        if p >= 1 then self:SetScript("OnUpdate", nil); if done then done() end end
    end)
    step(0)
end

local function anchor()
    local b = _G.OneMoreQuestMinimapButton
    if b and b.IsShown and b:IsShown() then return b end
    return Minimap or UIParent
end

local function glowIcon()
    local b = _G.OneMoreQuestMinimapButton
    if not (b and b.glow) then return end
    local g = CreateFrame("Frame")
    animate(g, 0.8, function(p) b.glow:SetAlpha(p < 0.3 and p / 0.3 or (1 - p) / 0.7) end, function() b.glow:SetAlpha(0) end)
end

-- slides a frame placed RIGHT of the icon's LEFT into the icon (or out of it with out = true)
local function fly(f, out, dur, done)
    local a = anchor()
    local dist = (f.w or 200) / 2 + 20
    animate(f, dur, function(p)
        local k = out and (1 - p) or p
        f:ClearAllPoints()
        f:SetPoint("RIGHT", a, "LEFT", -8 + dist * k, 0)
        f:SetScale(math.max(0.12, 1 - 0.85 * k))
        f:SetAlpha(1 - k)
    end, done)
end
U._Fly = fly

----------------------------------------------------------------------
-- Toasts: a new card slides into the icon
----------------------------------------------------------------------
local toast, toastQueue, toastBusy = nil, {}, false

local function buildToast()
    toast = CreateFrame("Frame", "OneMoreQuestBookToast", UIParent, BACKDROP)
    toast:SetSize(260, 60)
    toast.w = 260
    toast:SetFrameStrata("HIGH")
    toast:SetClampedToScreen(true)
    toast:EnableMouse(true)
    toast.bg = tex(toast, "BACKGROUND", .07, .05, .03, .96)
    toast.bg:SetAllPoints()
    toast.edges = {}
    for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 2 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 2 },
                         { "TOPLEFT", "BOTTOMLEFT", 2, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 2, nil } }) do
        local t = tex(toast, "BORDER")
        t:SetPoint(p[1]); t:SetPoint(p[2])
        if p[3] then t:SetWidth(p[3]) else t:SetHeight(p[4]) end
        toast.edges[i] = t
    end
    toast.round = toast.SetBackdrop and true or false
    if toast.round then
        toast:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = EDGE, edgeSize = 14,
                            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        toast:SetBackdropColor(.07, .05, .03, .96)
        toast.bg:Hide()
        for _, t in ipairs(toast.edges) do t:Hide() end
    end
    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetSize(40, 40); toast.icon:SetPoint("LEFT", 10, 0)
    toast.head = font(toast:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), BODY_FONT, 10)
    toast.head:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 10, 1)
    toast.title = font(toast:CreateFontString(nil, "OVERLAY", "GameFontNormal"), TITLE_FONT, 15)
    toast.title:SetPoint("TOPLEFT", toast.head, "BOTTOMLEFT", 0, -2)
    toast.line = font(toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 10)
    toast.line:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -2); toast.line:SetWidth(190)
    toast.line:SetJustifyH("LEFT")
    toast.card = false
    toast:SetScript("OnEnter", function(self) if self.card then tooltip(self, self.card) end end)
    toast:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    toast:Hide()
end

local nextToast
local function showToast(item)
    if not toast then buildToast() end
    toastBusy = true
    U.toastShown = item
    local r, g, b = GOLD[1], GOLD[2], GOLD[3]
    toast.card = item.card or false
    if item.card then r, g, b = qcolor(L:Quality(item.card, item.tier)) end
    for _, t in ipairs(toast.edges) do t:SetColorTexture(r, g, b, 1) end
    if toast.round then toast:SetBackdropBorderColor(r, g, b, 1) end
    toast.icon:SetTexture(item.icon or (item.card and item.card.icon))
    toast.head:SetText(item.head or "New Journey card")
    toast.title:SetText(item.title or item.card.title)
    toast.title:SetTextColor(r, g, b)
    toast.line:SetText(item.line or L:Goal(item.card, item.tier))
    toast:SetScale(1); toast:SetAlpha(1)
    toast:ClearAllPoints()
    toast:SetPoint("RIGHT", anchor(), "LEFT", -8, 0)
    toast:Show()
    if OMQ.Sound and OMQ.Sound.Play then pcall(OMQ.Sound.Play, OMQ.Sound, "popup") end
    local hold = item.hold or TOAST_HOLD
    C_Timer.After(hold, function()
        local function gone()
            toast:Hide(); toast:SetScale(1); toast:SetAlpha(1)
            glowIcon()
            toastBusy = false
            U.toastShown = nil
            nextToast()
        end
        if item.update then item.update = nil end
        fly(toast, false, 0.4, gone)
    end)
    if item.tick then
        local function again()
            if U.toastShown ~= item then return end
            item.tick(toast)
            C_Timer.After(1, again)
        end
        again()
    end
end

nextToast = function()
    if toastBusy then return end
    local item = table.remove(toastQueue, 1)
    if item then showToast(item) end
end

function U:Toast(item)
    toastQueue[#toastQueue + 1] = item
    nextToast()
end
function U:ToastCount() return #toastQueue + (toastBusy and 1 or 0) end

OMQ:On("LEDGER_NEW", function(fresh, tabs, first)
    if first then
        U:Toast({ head = "A new journey begins", title = "Forever Journey", hold = INTRO_HOLD,
                  icon = "Interface\\Icons\\INV_Misc_Book_09",
                  line = "Right-click the minimap icon and open it from the quick options." })
    end
    local shown = 0
    for _, n in ipairs(fresh or {}) do
        shown = shown + 1
        if shown > MAX_TOASTS then break end
        U:Toast({ card = n.card, tier = n.tier })
    end
    if #(fresh or {}) > MAX_TOASTS then
        U:Toast({ head = "Forever Journey", title = "+" .. (#fresh - MAX_TOASTS) .. " more cards",
                  icon = "Interface\\Icons\\INV_Misc_Book_09", line = "They wait in your journal." })
    end
    if OMQ.Options and OMQ.Options.Refresh then pcall(OMQ.Options.Refresh, OMQ.Options) end
    if U.frame and U.frame:IsShown() then U:Refresh() end
end)

----------------------------------------------------------------------
-- Showing a card to the group, and the counter
----------------------------------------------------------------------
U.restUntil = 0
local lastFlex                -- { fid, id } of my last shown card
local flexCard, flexQueue, flexBusy, flexItem = nil, {}, false, nil
local countered = {}          -- fid -> true (one counter per shown card)

function U:Resting() return time() < (self.restUntil or 0) end
U.cardRest = {}               -- card id -> time: the same card can be shown again only after 5 minutes
function U:CardResting(id) return time() < (self.cardRest[id] or 0) end

function U:Flex(id)
    local c = L:Card(id)
    local rec = c and L:Owned(id)
    if not rec then return false end
    if not OMQ:GetChannel() then OMQ:Print("join a group to show a card"); return false end
    if self:Resting() then OMQ:Print("showing cards rests for " .. mmss(self.restUntil - time())); return false end
    if self:CardResting(id) then OMQ:Print(c.title .. " can be shown again in " .. mmss(self.cardRest[id] - time())); return false end
    local me = OMQ:GetSelf()
    if not me then return false end
    local fid = tostring(time()) .. tostring(math.random(100, 999))
    if not OMQ:Send("LF", me.guid, me.name, id, rec.n or 1, fid) then return false end
    lastFlex = { fid = fid, id = id }
    self.cardRest[id] = time() + REST
    OMQ:Print("shown to the group: " .. c.title)
    return true
end

local function buildFlex()
    flexCard = newCard(UIParent, 200, 290)
    flexCard:SetFrameStrata("HIGH")
    flexCard:SetClampedToScreen(true)
    flexCard.banner = font(flexCard:CreateFontString(nil, "OVERLAY", "GameFontNormal"), TITLE_FONT, 17)
    flexCard.banner:SetPoint("TOP", flexCard, "BOTTOM", 0, -6)
    -- what the shown card means for this dad, in the free space above the footer
    flexCard.note = font(flexCard:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 12, true)
    flexCard.note:SetPoint("BOTTOM", flexCard, "BOTTOM", 0, 52); flexCard.note:SetWidth(200 - 2 * flexCard.m)
    flexCard.note:SetJustifyH("CENTER")
    if flexCard.note.SetSpacing then flexCard.note:SetSpacing(3) end
    U.flexCard = flexCard
    flexCard:SetScript("OnEnter", function(self)
        self.hover = true
        local own = L:Owned(self.card.id)
        tooltip(self, self.card, own and ("Left-click: counter " .. tostring(flexItem and flexItem.name)) or nil, flexItem and flexItem.name)
    end)
    flexCard:SetScript("OnLeave", function(self) self.hover = false; if GameTooltip then GameTooltip:Hide() end end)
    flexCard:SetScript("OnClick", function(_, mouse) if mouse == "LeftButton" then U:Counter() end end)
    flexCard:Hide()
end

local nextFlex
local function flexDone()
    flexCard:Hide(); flexCard:SetScale(1); flexCard:SetAlpha(1)
    flexBusy, flexItem = false, nil
    glowIcon()
    nextFlex()
end
local function flexBack()
    if not flexBusy or flexCard.leaving then return end
    flexCard.leaving = true
    fly(flexCard, false, 0.4, function() flexCard.leaving = false; flexDone() end)
end
U._FlexBack = flexBack

local function showFlex(item)
    if not flexCard then buildFlex() end
    flexBusy, flexItem = true, item
    local res = L:Evaluate()
    local own = L:Owned(item.card.id)
    paint(flexCard, item.card, "own", nil, own and { n = item.tier, t = own.t, l = own.l, g = own.g } or { n = item.tier }, res and res[item.card.id] and res[item.card.id].v)
    flexCard.footL:SetText(""); flexCard.footR:SetText(""); flexCard.extra:SetText("")
    if own then
        flexCard.note:SetText("You own this card\nLeft-click to counter " .. item.name); flexCard.note:SetTextColor(.08, .45, .05)
    else
        flexCard.note:SetText("You miss this card\nYou got flexed by " .. item.name); flexCard.note:SetTextColor(.55, .08, .05)
    end
    flexCard.banner:SetText(item.name .. " shows a card!")
    flexCard:Show()
    if OMQ.Sound and OMQ.Sound.Play then pcall(OMQ.Sound.Play, OMQ.Sound, "popup") end
    fly(flexCard, true, 0.5)
    local token = {}
    flexCard.token = token
    local function wait(left)
        if flexCard.token ~= token or not flexBusy then return end
        if left <= 0 and not flexCard.hover then flexBack(); return end
        C_Timer.After(1, function() wait(left - 1) end)
    end
    wait(FLEX_HOLD)
end

nextFlex = function()
    if flexBusy then return end
    local item = table.remove(flexQueue, 1)
    if item then showFlex(item) end
end

function U:FlexShown() return flexBusy and flexItem or nil end

-- a left click on a shown card that I own
function U:Counter()
    local item = flexItem
    if not item or not L:Owned(item.card.id) or countered[item.fid] then return false end
    local me = OMQ:GetSelf()
    if not me then return false end
    countered[item.fid] = true
    OMQ:Send("LC", me.guid, me.name, item.guid, item.fid)
    flexBack()
    return true
end

local function onFlex(fields)
    local guid, name, id, tier, fid = fields[1], fields[2], fields[3], tonumber(fields[4]), fields[5]
    local me = OMQ:GetSelf()
    if not guid or (me and guid == me.guid) then return end
    local c = L:Card(id or "")
    if not c or not L:Open() then return end
    L:MarkSeen(id, name, tier)
    if OMQ.db and OMQ.db.options and OMQ.db.options.bookFlexOff then return end
    flexQueue[#flexQueue + 1] = { guid = guid, name = name or "?", card = c, tier = tier or 1, fid = fid }
    nextFlex()
    if U.frame and U.frame:IsShown() then U:Refresh() end
end

local function onCounter(fields)
    local guid, name, target, fid = fields[1], fields[2], fields[3], fields[4]
    local me = OMQ:GetSelf()
    if not me or target ~= me.guid or guid == me.guid then return end
    if not lastFlex or lastFlex.fid ~= fid or lastFlex.countered then return end
    lastFlex.countered = true
    U.restUntil = time() + REST
    local c = L:Card(lastFlex.id)
    U:Toast({ head = "Countered", title = "Countered by " .. tostring(name) .. " - 5 minutes of quiet",
              icon = c and c.icon, hold = COUNTER_HOLD, line = "Showing cards again in " .. mmss(REST),
              tick = function(t) t.line:SetText("Showing cards again in " .. mmss(U.restUntil - time())) end })
end

OMQ:RegisterMessage("LF", onFlex)
OMQ:RegisterMessage("LC", onCounter)

----------------------------------------------------------------------
-- The window
----------------------------------------------------------------------
U.tab, U.page = "leveling", 1

local function cardState(c, res)
    if L:Owned(c.id) then return "own" end
    if L:Seen(c.id) then return "seen" end
    return "down"
end

local function build()
    local W = COLS * CW + (COLS - 1) * GAP + 2 * PAD
    local H = 64 + 14 + ROWS * CH + (ROWS - 1) * GAP + 40
    local f = CreateFrame("Frame", "OneMoreQuestBook", UIParent)
    U.frame = f
    -- the tabs stand in a column on the right, as wide as the longest name needs; the card view keeps its size
    local probe = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local longest = 0
    for _, t in ipairs(L.TABS) do
        probe:SetText(t.name)
        local w = probe.GetStringWidth and probe:GetStringWidth()
        if type(w) ~= "number" or w <= 0 then w = #t.name * 7 end
        if w > longest then longest = w end
    end
    probe:SetText(""); probe:Hide()
    local TW = math.max(U.TAB_MIN, math.ceil(longest) + 28)
    U.tabWidth = TW
    f:SetSize(W + TW + 8, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f.bg = tex(f, "BACKGROUND", .11, .086, .063, .98); f.bg:SetAllPoints()
    f.head = tex(f, "BORDER", .15, .114, .075, 1)
    f.head:SetPoint("TOPLEFT"); f.head:SetPoint("TOPRIGHT"); f.head:SetHeight(64)
    f.line = tex(f, "BORDER", .54, .43, .18, 1)
    f.line:SetPoint("TOPLEFT", 0, -64); f.line:SetPoint("TOPRIGHT", 0, -64); f.line:SetHeight(1)
    f.top = tex(f, "BORDER", .89, .71, .29, 1)
    f.top:SetPoint("TOPLEFT"); f.top:SetPoint("TOPRIGHT"); f.top:SetHeight(3)
    f.portrait = f:CreateTexture(nil, "ARTWORK")
    f.portrait:SetSize(44, 44); f.portrait:SetPoint("TOPLEFT", 14, -10)
    f.portrait:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", f.portrait, "TOPRIGHT", 12, -4)
    f.title:SetText("Forever Journey")
    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    local close = CreateFrame("Button", nil, f)
    close:SetSize(28, 28); close:SetPoint("TOPRIGHT", -8, -8)
    local cx = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cx:SetPoint("CENTER"); cx:SetText("x"); cx:SetTextColor(.79, .73, .61)
    close:SetScript("OnClick", function() U:Hide() end)
    -- "Cards of others" with a visible on/off switch
    f.flexBtn = CreateFrame("Button", nil, f)
    f.flexBtn:SetSize(170, 22); f.flexBtn:SetPoint("RIGHT", close, "LEFT", -12, 0)
    local sw = CreateFrame("Frame", nil, f.flexBtn, BACKDROP)
    sw:SetSize(46, 20); sw:SetPoint("RIGHT")
    if sw.SetBackdrop then
        sw:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = EDGE, edgeSize = 10,
                         insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    end
    sw.knob = tex(sw, "OVERLAY", .93, .9, .82, 1)
    sw.knob:SetSize(14, 12)
    sw.text = font(sw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 9)
    f.flexBtn.switch = sw
    f.flexBtn.label = f.flexBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.flexBtn.label:SetPoint("RIGHT", sw, "LEFT", -8, 0)
    f.flexBtn:SetScript("OnClick", function()
        OMQ.db.options.bookFlexOff = not OMQ.db.options.bookFlexOff or nil
        U:Refresh()
    end)

    f.cards = {}
    for i = 1, COLS * ROWS do
        local cw = newCard(f, CW, CH)
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        cw:SetPoint("TOPLEFT", PAD + col * (CW + GAP), -(64 + 14 + row * (CH + GAP)))
        cw:SetScript("OnEnter", function(self)
            if self.state == "down" or not self.card then return end
            local hint
            if self.state == "own" then
                hint = U:CardResting(self.card.id) and ("Shown recently - again in " .. mmss(U.cardRest[self.card.id] - time()))
                    or "Click: show it to your group"
            end
            tooltip(self, self.card, hint)
        end)
        cw:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        cw:SetScript("OnClick", function(self) if self.state == "own" then U:Flex(self.card.id) end end)
        f.cards[i] = cw
    end
    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.summary:SetPoint("TOPLEFT", PAD + CW + 2 * GAP, -(64 + 18))
    f.summary:SetWidth(W - 2 * PAD - CW - 2 * GAP)
    f.summary:SetJustifyH("LEFT"); f.summary:SetJustifyV("TOP")

    local pagerY = 64 + 14 + ROWS * CH + (ROWS - 1) * GAP + 8
    f.prev = CreateFrame("Button", nil, f)
    f.prev:SetSize(40, 24); f.prev:SetPoint("TOP", f, "TOPLEFT", W / 2 - 80, -pagerY)
    f.prev.label = f.prev:CreateFontString(nil, "OVERLAY", "GameFontNormal"); f.prev.label:SetPoint("CENTER"); f.prev.label:SetText("<")
    f.prev:SetScript("OnClick", function() U.page = math.max(1, U.page - 1); U:Refresh() end)
    f.next = CreateFrame("Button", nil, f)
    f.next:SetSize(40, 24); f.next:SetPoint("TOP", f, "TOPLEFT", W / 2 + 80, -pagerY)
    f.next.label = f.next:CreateFontString(nil, "OVERLAY", "GameFontNormal"); f.next.label:SetPoint("CENTER"); f.next.label:SetText(">")
    f.next:SetScript("OnClick", function() U.page = U.page + 1; U:Refresh() end)
    f.pageText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.pageText:SetPoint("TOP", f, "TOPLEFT", W / 2, -(pagerY + 6))

    f.tabs = {}
    f.tabLine = tex(f, "BORDER", .54, .43, .18, 1)
    f.tabLine:SetPoint("TOPLEFT", W, -64); f.tabLine:SetPoint("BOTTOMLEFT", W, 0); f.tabLine:SetWidth(1)
    local step = math.min(30, math.floor((H - 64 - 14 - 8) / #L.TABS))
    for i, t in ipairs(L.TABS) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(TW, step - 2)
        b:SetPoint("TOPLEFT", W + 4, -(64 + 14 + (i - 1) * step))
        b.bg = tex(b, "BACKGROUND", .07, .05, .03, 1); b.bg:SetAllPoints()
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.label:SetPoint("LEFT", 12, 0)
        b.id = t.id
        b:SetScript("OnClick", function(self)
            if not L:TabOpen(self.id) then return end
            U.tab, U.page = self.id, 1
            U:Refresh()
        end)
        f.tabs[i] = b
    end
    f:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestBook") end
end

local function summaryText()
    local b = L:Book()
    if not b then return "" end
    local quests, maps = 0, 0
    for _ in pairs(b.quests or {}) do quests = quests + 1 end
    for _ in pairs(b.zones or {}) do maps = maps + 1 end
    local best, mate = 0, nil
    for _, p in pairs(b.people or {}) do if p.dad and (p.s or 0) > best then best, mate = p.s, p.nm end end
    local own, all = L:Counts()
    local lines = {
        "Played: " .. math.floor((b.secs or 0) / 3600) .. " hours",
        "Foes defeated: " .. (b.kills.total or 0),
        "Quests completed: " .. quests,
        "Zones visited: " .. maps,
        "Deaths: " .. #(b.deaths or {}),
        "Dungeon visits: " .. #(b.dungeons or {}),
        "Favourite companion: " .. (mate and (mate .. " (" .. math.floor(best / 3600) .. " hours)") or "-"),
        "Cards: " .. own .. " of " .. all,
    }
    return table.concat(lines, "\n")
end

function U:Refresh()
    local f = self.frame
    if not f then return end
    if not L:TabOpen(self.tab) then
        for _, t in ipairs(L.TABS) do if L:TabOpen(t.id) then self.tab = t.id; break end end
    end
    local list = L:TabCards(self.tab)
    local per = COLS * ROWS
    local pages = math.max(1, math.ceil(#list / per))
    self.page = math.min(math.max(1, self.page), pages)
    local res = L:Evaluate() or {}
    local own, all = L:Counts(self.tab)
    local ownAll, allAll = L:Counts()
    f.sub:SetText(tabName(self.tab) .. " - " .. own .. " of " .. all .. " cards - " .. ownAll .. " of " .. allAll .. " in total")
    local on = not OMQ.db.options.bookFlexOff
    local sw = f.flexBtn.switch
    f.flexBtn.label:SetText("Cards of others")
    sw.state = on and "on" or "off"
    sw.knob:ClearAllPoints(); sw.text:ClearAllPoints()
    if on then
        if sw.SetBackdropColor then sw:SetBackdropColor(.12, .55, .1, 1); sw:SetBackdropBorderColor(.3, .85, .25, 1) end
        sw.knob:SetPoint("RIGHT", -4, 0); sw.text:SetPoint("LEFT", 6, 0); sw.text:SetText("On")
    else
        if sw.SetBackdropColor then sw:SetBackdropColor(.2, .18, .15, 1); sw:SetBackdropBorderColor(.5, .47, .42, 1) end
        sw.knob:SetPoint("LEFT", 4, 0); sw.text:SetPoint("RIGHT", -5, 0); sw.text:SetText("Off")
    end
    for i, cw in ipairs(f.cards) do
        local idx = (self.page - 1) * per + i
        local c = list[idx]
        if c then
            local state = cardState(c, res)
            paint(cw, c, state, string.format("%02d / %02d", idx, #list), L:Owned(c.id), res[c.id] and res[c.id].v)
            cw:Show()
        else
            cw:Hide()
        end
    end
    if self.tab == "summary" then f.summary:SetText(summaryText()); f.summary:Show() else f.summary:Hide() end
    f.pageText:SetText("Page " .. self.page .. " of " .. pages)
    if pages > 1 then f.prev:Show(); f.next:Show(); f.pageText:Show() else f.prev:Hide(); f.next:Hide(); f.pageText:Hide() end
    for _, b in ipairs(f.tabs) do
        if b.id == self.tab then
            b.bg:SetColorTexture(.11, .086, .063, 1); b.label:SetText(tabName(b.id)); b.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        elseif L:TabOpen(b.id) then
            b.bg:SetColorTexture(.09, .067, .043, 1); b.label:SetText(tabName(b.id)); b.label:SetTextColor(.79, .73, .61)
        else
            b.bg:SetColorTexture(.06, .047, .031, 1); b.label:SetText("???"); b.label:SetTextColor(.43, .34, .16)
        end
    end
end

function U:Show()
    if not L:Open() then return false end
    if not self.frame then build() end
    self:Refresh()
    self.frame:Show()
    return true
end
function U:Hide() if self.frame then self.frame:Hide() end end
function U:Toggle()
    if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end
end
U._Paint, U._NewCard = paint, newCard

----------------------------------------------------------------------
-- Test command (not in /omq help)
----------------------------------------------------------------------
local function demo()
    local c = L:Card("dragon")
    U:Toast({ card = c, tier = 3 })
    if not flexCard then buildFlex() end
    flexQueue[#flexQueue + 1] = { guid = "demo", name = "Demo", card = L:Card("lava"), tier = 1, fid = "demo" }
    nextFlex()
    U:Toast({ head = "Countered", title = "Countered by Demo - 5 minutes of quiet", icon = c.icon,
              hold = COUNTER_HOLD, line = "Showing cards again in 5:00" })
end

OMQ:RegisterCommand("book", function(arg)
    arg = (arg or ""):lower()
    if arg == "demo" then demo(); return end
    if arg == "check" then
        local fresh, tabs = L:Check()
        OMQ:Print("book check: " .. (fresh and (#fresh .. " new, " .. #tabs .. " tabs") or "below level " .. L.MIN_LEVEL))
        return
    end
    if arg == "icons" then
        local missing = {}
        for _, c in ipairs(L.CARDS) do
            if GetFileIDFromPath and not GetFileIDFromPath(c.icon) then missing[#missing + 1] = c.id end
        end
        OMQ:Print("book icons missing: " .. (#missing > 0 and table.concat(missing, " ") or "none"))
        return
    end
    if arg == "diag" then
        local own, all = L:Counts()
        local keys = {}
        for k, v in pairs(L.diag) do keys[#keys + 1] = k .. "=" .. v end
        table.sort(keys)
        OMQ:Print("book " .. own .. "/" .. all .. ", open " .. tostring(L:Open()) .. ", rest " .. mmss(U.restUntil - time()) .. ", " .. table.concat(keys, " "))
        return
    end
    if not U:Show() then OMQ:Print("book: nothing yet") end
end, nil, true)
