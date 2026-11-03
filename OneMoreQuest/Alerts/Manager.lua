-- One More Quest: alert manager and card frame (sections 5.3 and 7.1)
-- Rules report what is wrong right now. The manager keeps one card per problem,
-- hides cards during combat, and handles dismissing (5 minute timer).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local DISMISS_SECONDS = 300         -- decision 49 and 75
local EVAL_INTERVAL = 1             -- seconds between rule evaluations
local MAX_CARDS = 3                 -- decision 74
local CARD_W, CARD_H, GAP = 330, 50, 6
local FADE_SPEED = 4                -- alpha per second
local CARD_SCALE = 1.2                -- cards are 20 percent larger than the base size

local M = {}
OMQ.Alerts = M

M.rules = {}                        -- id -> { id, name, check = function() -> list }
M.ruleOrder = {}
local active = {}                   -- key -> alert { key, rule, text, icon, color, since }
local dismissed = {}                -- key -> GetTime() when the timer ends (memory only)
local away = {}                     -- key -> rule id: clicked away with the right button (decision 328), until the problem is gone
local permanentlyDismissed          -- defined further down (rank cards)
local sequence = 0
local frame, cards, moreText
local moveMode = false
local inCombat = false
-- the card frame holds secure buttons, so it is protected itself: no Show, Hide, move or mouse change while
-- the combat lockdown is on (it caused "Interface action failed" at the start of a fight)
local function locked() return InCombatLockdown and InCombatLockdown() and true or false end
local atAuction = false     -- the auction house is open: no cards (decision 261)
local alpha, targetAlpha = 0, 1

----------------------------------------------------------------------
-- Rules
----------------------------------------------------------------------
-- rule = { id, name (for the option list), check = function() return list|nil end }
-- Each list entry: { key, text, icon, color = {r,g,b} }
function M:Register(rule)
    self.rules[rule.id] = rule
    self.ruleOrder[#self.ruleOrder + 1] = rule.id
end

-- the switch of the rule itself, regardless of the category master switch
function M:IsRuleSet(id)
    local e = OMQ.db.alerts.enabled[id]
    return e == nil or e == true
end

function M:IsRuleEnabled(id)
    return OMQ:Master("alerts") and self:IsRuleSet(id)
end

function M:IsSnoozed()
    return (OMQ.db.options.snoozeUntil or 0) > time()
end

----------------------------------------------------------------------
-- Evaluation
----------------------------------------------------------------------
function M:Evaluate()
    local seen = {}
    if not self:IsSnoozed() then
        for _, id in ipairs(self.ruleOrder) do
            if self:IsRuleEnabled(id) then
                local rule = self.rules[id]
                local ok, list = pcall(rule.check)
                if not ok then
                    OMQ:Error("alert " .. id, list)
                    list = "keep"
                end
                if list == "keep" then
                    -- data not readable right now (for example in combat): keep what we show
                    for key, a in pairs(active) do
                        if a.rule == id then seen[key] = true end
                    end
                elseif list then
                    -- a card clicked away stays away while its problem lasts; once the rule no longer
                    -- reports it, the card may come back with the next problem (decision 328)
                    local reported = {}
                    for _, a in ipairs(list) do reported[a.key] = true end
                    for key, rid in pairs(away) do
                        if rid == id and not reported[key] then away[key] = nil; dismissed[key] = nil end
                    end
                    for _, a in ipairs(list) do
                        seen[a.key] = true
                        local until_ = dismissed[a.key]
                        if permanentlyDismissed(a.key) then
                            -- dismissed for good (see M:Dismiss)
                        elseif until_ and GetTime() < until_ then
                            -- dismissed: stays away until the timer ends
                        else
                            dismissed[a.key] = nil
                            local cur = active[a.key]
                            if not cur then
                                sequence = sequence + 1
                                a.rule, a.since, a.order = id, GetTime(), sequence
                                active[a.key] = a
                            else
                                cur.text, cur.icon, cur.color = a.text, a.icon or cur.icon, a.color or cur.color
                                cur.cast, cur.unit, cur.go, cur.open = a.cast, a.unit, a.go, a.open
                                cur.useItem, cur.weapon = a.useItem, a.weapon
                                cur.tipLines = a.tipLines
                                cur.title, cur.sub, cur.tag = a.title, a.sub, a.tag
                            end
                        end
                    end
                end
            end
        end
    end
    -- a problem that is gone disappears by itself (decision 76)
    for key in pairs(active) do
        if not seen[key] then active[key] = nil end
    end
    self:Render()
end

-- Active alerts, newest first.
function M:GetActive()
    local list = {}
    for _, a in pairs(active) do list[#list + 1] = a end
    table.sort(list, function(x, y) return x.order > y.order end)
    return list
end

-- "Spell not on a bar" cards (key "rank:...") stay away for good once dismissed, per character:
-- they would only come back every 5 minutes for a spell the player decided to keep off the bars.
-- A higher rank is a different key and shows again. "Bring back dismissed alerts" clears them.
local function rankStore(create)
    local guid = UnitGUID("player")
    if not guid then return nil end
    local a = OMQ.db.alerts
    a.rankDismissed = a.rankDismissed or {}
    if create and not a.rankDismissed[guid] then a.rankDismissed[guid] = {} end
    return a.rankDismissed[guid]
end

-- profession tool cards (key "tool:...", decision 251) the same way, when clicked away with the right button
local function permanentKind(key)
    return type(key) == "string" and (key:find("^rank:") or key:find("^tool:") or key:find("^consd?:")) and true or false
end

function permanentlyDismissed(key)
    if not permanentKind(key) then return false end
    local s = rankStore(false)
    return s and s[key] and true or false
end

-- One click logic for every card (decision 328):
--   left click      the action of the card (cast, arrow, window); a card without one goes away for 5 minutes
--   right click     the card goes away (M:Dismiss(key, true)): for good for the training, tool and consumable cards,
--                   otherwise as long as its problem lasts
--   shift + right   the card snoozes for 5 minutes (M:Dismiss(key, false, true)) and then comes back
function M:Dismiss(key, forGood, snooze)
    local persisted = false
    if type(key) == "string" and not snooze
        and (key:find("^rank:") or (forGood and (key:find("^tool:") or key:find("^consd?:")))) then
        local s = rankStore(true)
        if s then s[key] = true; persisted = true end
    end
    dismissed[key] = GetTime() + DISMISS_SECONDS
    if forGood and not snooze and not persisted then
        away[key] = (active[key] and active[key].rule) or true
        dismissed[key] = math.huge
    end
    active[key] = nil
    if self._MarkDismissed then self:_MarkDismissed(key) end
    self:Render()
    OMQ:Fire("ALERT_DISMISSED", key)
end

function M:ClearDismissals() dismissed = {}; away = {} end

-- the separate cards (rage) ask whether they were clicked away, and clear it when their problem is gone
function M:IsAway(key) return dismissed[key] ~= nil and GetTime() < dismissed[key] end
function M:ClearAway(key) away[key] = nil; dismissed[key] = nil end
function M:DismissedForGood(key) return permanentlyDismissed(key) end

-- "Reset consumable reminders" (decision 266): the clicked away consumable cards come back
function M:ResetConsumables()
    local s = rankStore(false)
    if s then for k in pairs(s) do if k:find("^consd?:") then s[k] = nil end end end
    for k in pairs(dismissed) do if type(k) == "string" and k:find("^consd?:") then dismissed[k] = nil end end
    self:Evaluate()
end

-- Brings back every dismissed card: the 5 minute timers, the training cards of
-- this character, and the quest info cards.
function M:ResetDismissed()
    dismissed = {}
    away = {}
    local guid0 = UnitGUID("player")
    if guid0 and OMQ.db.alerts.rankDismissed then OMQ.db.alerts.rankDismissed[guid0] = nil end
    local guid = UnitGUID("player")
    if OMQ.db.alerts.trainDone and guid then OMQ.db.alerts.trainDone[guid] = nil end
    OMQ.db.quests.ignored = {}
    OMQ.db.quests.notified = {}
    self:Evaluate()
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local savePosition, applyPosition
function M:ResetPosition()
    OMQ.db.alerts.point = nil
    if applyPosition and frame then applyPosition() end
end

function savePosition()
    local point, _, relPoint, x, y = frame:GetPoint()
    OMQ.db.alerts.point = { point or "TOP", relPoint or "TOP", x or 0, y or -160 }
end

function applyPosition()
    local p = OMQ.db.alerts.point or { "TOP", "TOP", 1, -178 }   -- default layout (decision 190)
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

----------------------------------------------------------------------
-- Card look (decision 183, style C "medallion") and motion
----------------------------------------------------------------------
-- small coloured tag above the title, per rule
local TAGS = { drink = "DRINK", repair = "REPAIR", train = "TRAINER", prof = "PROFESSION", rank = "SPELL RANK",
               buff = "BUFF", talent = "TALENTS", ammo = "AMMO", betmail = "BET CHECK", drinks = "DRINKS", tracking = "TRACKING" }
M.TAGS = TAGS

-- "Repair: most damaged item at 18%" -> title "Repair", detail "Most damaged item at 18%"
function M.SplitText(text)
    text = tostring(text or "")
    local a, b = text:match("^([^:]+):%s*(.+)$")
    if a and #a <= 28 then
        return a, (b:gsub("^%l", string.upper))
    end
    return text, ""
end

local IN_TIME, SHINE_TIME, MOVE_TIME, OUT_TIME, SOLVED_TIME = 0.25, 0.6, 0.2, 0.18, 0.4
M.MOTION = { IN_TIME = IN_TIME, MOVE_TIME = MOVE_TIME, OUT_TIME = OUT_TIME, SOLVED_TIME = SOLVED_TIME }
local GOLD, GOLD_DARK = { 0.63, 0.50, 0.21 }, { 0.29, 0.23, 0.10 }

local function edge(parent, layer, c, inset)
    local t = {}
    for i = 1, 4 do
        local e = parent:CreateTexture(nil, layer)
        e:SetColorTexture(c[1], c[2], c[3], 1)
        t[i] = e
    end
    t[1]:SetPoint("TOPLEFT", inset, -inset); t[1]:SetPoint("TOPRIGHT", -inset, -inset); t[1]:SetHeight(1)
    t[2]:SetPoint("BOTTOMLEFT", inset, inset); t[2]:SetPoint("BOTTOMRIGHT", -inset, inset); t[2]:SetHeight(1)
    t[3]:SetPoint("TOPLEFT", inset, -inset); t[3]:SetPoint("BOTTOMLEFT", inset, inset); t[3]:SetWidth(1)
    t[4]:SetPoint("TOPRIGHT", -inset, -inset); t[4]:SetPoint("BOTTOMRIGHT", -inset, inset); t[4]:SetWidth(1)
    return t
end

-- the visible part of a card: a plain frame, so it can move and fade in combat-free time
-- without touching the secure button that takes the clicks
local function makeSkin(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(CARD_W, CARD_H)
    s.bg = s:CreateTexture(nil, "BACKGROUND")
    s.bg:SetAllPoints()
    s.bg:SetColorTexture(0.086, 0.094, 0.122, 0.96)
    s.tint = s:CreateTexture(nil, "BORDER")
    s.tint:SetAllPoints()
    s.edgeOut = edge(s, "ARTWORK", GOLD, 0)
    s.edgeIn = edge(s, "ARTWORK", GOLD_DARK, 3)

    -- the shine runs inside the card only
    s.clip = CreateFrame("Frame", nil, s)
    s.clip:SetAllPoints()
    if s.clip.SetClipsChildren then pcall(s.clip.SetClipsChildren, s.clip, true) end
    s.shine = s.clip:CreateTexture(nil, "OVERLAY")
    s.shine:SetSize(46, CARD_H)
    s.shine:SetColorTexture(1, 0.89, 0.55, 0.35)
    if s.shine.SetBlendMode then s.shine:SetBlendMode("ADD") end
    s.shine:SetPoint("LEFT", s, "LEFT", -60, 0)
    s.shine:Hide()

    -- the medallion over the left edge, like a minimap button
    s.medal = CreateFrame("Frame", nil, s)
    s.medal:SetSize(36, 36)
    s.medal:SetPoint("LEFT", s, "LEFT", -16, 0)
    s.medalBg = s.medal:CreateTexture(nil, "BACKGROUND")
    s.medalBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    s.medalBg:SetSize(26, 26)
    s.medalBg:SetPoint("TOPLEFT", 6, -5)
    s.icon = s.medal:CreateTexture(nil, "ARTWORK")
    s.icon:SetSize(24, 24)
    s.icon:SetPoint("TOPLEFT", 7, -6)
    if s.icon.SetMask then pcall(s.icon.SetMask, s.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
    s.ring = s.medal:CreateTexture(nil, "OVERLAY")
    s.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    s.ring:SetSize(62, 62)
    s.ring:SetPoint("TOPLEFT", 0, 0)
    s.glow = s.medal:CreateTexture(nil, "OVERLAY")
    s.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    if s.glow.SetBlendMode then s.glow:SetBlendMode("ADD") end
    s.glow:SetVertexColor(0.49, 0.82, 0.44)
    s.glow:SetSize(70, 70)
    s.glow:SetPoint("CENTER", s.medal, "CENTER", 0, 0)
    s.glow:SetAlpha(0)

    s.tag = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s.tag:SetPoint("TOPLEFT", 30, -6)
    s.tag:SetJustifyH("LEFT")
    s.title = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s.title:SetPoint("TOPLEFT", 30, -18)
    s.title:SetPoint("RIGHT", s, "RIGHT", -26, 0)
    s.title:SetJustifyH("LEFT")
    s.title:SetTextColor(0.95, 0.82, 0.48)
    s.sub = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s.sub:SetPoint("TOPLEFT", 30, -33)
    s.sub:SetPoint("RIGHT", s, "RIGHT", -26, 0)
    s.sub:SetJustifyH("LEFT")
    s.sub:SetTextColor(0.79, 0.80, 0.84)
    s.close = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s.close:SetPoint("TOPRIGHT", -9, -6)
    s.close:SetText("x")
    s.close:SetTextColor(0.55, 0.58, 0.63)
    return s
end

local function fill(s, a)
    local title, sub = a.title, a.sub
    if not title then title, sub = M.SplitText(a.text) end
    local c = a.color or { 0.89, 0.71, 0.29 }
    s.tag:SetText(a.tag or TAGS[a.rule] or "ALERT")
    s.tag:SetTextColor(c[1], c[2], c[3])
    s.title:SetText(title or "")
    s.sub:SetText(sub or "")
    s.title:ClearAllPoints()
    s.title:SetPoint("TOPLEFT", 30, (sub and sub ~= "") and -18 or -24)
    s.title:SetPoint("RIGHT", s, "RIGHT", -26, 0)
    s.icon:SetTexture(a.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    s.tint:SetColorTexture(c[1], c[2], c[3], 0.06)
    s.shown = { title = title, sub = sub, tag = a.tag or TAGS[a.rule] or "ALERT", color = c, icon = a.icon }
end

M.MakeSkin, M.FillSkin, M.CARD_W, M.CARD_H = makeSkin, fill, CARD_W, CARD_H

-- one running tween per skin: offsets x and y and the alpha go to their targets
local tweens = {}
local twOf, shineAt, glowAt = {}, {}, {}     -- kept apart from the frames
local function ease(p) return 1 - (1 - p) * (1 - p) end
local function place(s, x, y)
    s:ClearAllPoints()
    s:SetPoint("TOPLEFT", s.anchor, "TOPLEFT", x, y)
end
local function tween(s, from, to, dur, delay, after)
    twOf[s] = { t0 = GetTime() + (delay or 0), dur = dur, from = from, to = to, after = after }
    tweens[s] = true
    place(s, from.x or 0, from.y or 0)
    s:SetAlpha(from.a or 1)
end
M._tweens = tweens
function M._TweenOf(s) return twOf[s] end

local function stepTweens()
    local t = GetTime()
    for s in pairs(tweens) do
        local w = twOf[s]
        if not w then tweens[s] = nil
        else
            local p = (t - w.t0) / w.dur
            if p >= 0 then
                p = math.min(1, p)
                local e = ease(p)
                local fx, fy, fa = w.from.x or 0, w.from.y or 0, w.from.a or 1
                local tx, ty, ta = w.to.x or 0, w.to.y or 0, w.to.a or 1
                place(s, fx + (tx - fx) * e, fy + (ty - fy) * e)
                s:SetAlpha(fa + (ta - fa) * e)
                if p >= 1 then
                    twOf[s] = nil
                    tweens[s] = nil
                    if w.after then w.after(s) end
                end
            end
        end
        -- the shine and the green flash run on their own clocks
    end
    for s in pairs(M._fx or {}) do
        local done = true
        if shineAt[s] then
            local p = (t - shineAt[s]) / SHINE_TIME
            if p >= 0 and p <= 1 then
                s.shine:Show()
                s.shine:ClearAllPoints()
                s.shine:SetPoint("LEFT", s, "LEFT", -60 + (CARD_W + 80) * p, 0)
                s.shine:SetAlpha(p < 0.2 and p / 0.2 or (1 - p))
                done = false
            elseif p > 1 then s.shine:Hide(); shineAt[s] = nil
            else done = false end
        end
        if glowAt[s] then
            local p = (t - glowAt[s]) / 0.3
            if p >= 0 and p <= 1 then s.glow:SetAlpha(p < 0.4 and p / 0.4 or (1 - p) / 0.6); done = false
            elseif p > 1 then s.glow:SetAlpha(0); glowAt[s] = nil
            else done = false end
        end
        if done then M._fx[s] = nil end
    end
end
M._stepTweens = stepTweens

local function fx(s, kind)
    M._fx = M._fx or {}
    M._fx[s] = true
    if kind == "shine" then shineAt[s] = GetTime() + IN_TIME * 0.6 end
    if kind == "glow" then glowAt[s] = GetTime() end
end

-- weapon oils and stones (decision 291): a click on the card shows the worn weapons as icons next to it;
-- a click on one applies the item to that weapon (a macro: use the item, then the slot)
local WEAPON_SLOTS = { 16, 17 }
local function wornWeapon(slot)
    local tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slot)
    if not tex then return nil end
    if slot == 17 then                                    -- a shield or a held item takes no oil
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
        local _, _, _, loc = C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(link or 0)
        if loc ~= "INVTYPE_WEAPON" and loc ~= "INVTYPE_WEAPONOFFHAND" then return nil end
    end
    return tex
end
function M.RefreshWeapons(card)
    if locked() then return end           -- secure buttons: no Show, Hide or move in combat
    if type(rawget(card, "wb")) ~= "table" then card.wb = {} end
    local n = 0
    for _, slot in ipairs(WEAPON_SLOTS) do
        local b = card.wb[slot]
        if not b then
            b = CreateFrame("Button", nil, card, "SecureActionButtonTemplate")
            b:SetSize(CARD_H - 8, CARD_H - 8)
            b:RegisterForClicks("AnyUp", "AnyDown")
            b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetAllPoints()
            b.edge = b:CreateTexture(nil, "BACKGROUND"); b.edge:SetPoint("TOPLEFT", -2, 2); b.edge:SetPoint("BOTTOMRIGHT", 2, -2)
            b.edge:SetColorTexture(0.95, 0.82, 0.48, 1)
            b.slot = slot
            b:SetScript("OnEnter", function(self)
                if GameTooltip then GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetInventoryItem("player", self.slot); GameTooltip:Show() end
            end)
            b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            b:SetScript("PostClick", function(self, _, down)
                if down then return end
                card.wShow = false
                M.RefreshWeapons(card)
            end)
            card.wb[slot] = b
        end
        local tex = rawget(card, "weapon") and rawget(card, "wShow") and wornWeapon(slot)
        if tex then
            b.icon:SetTexture(tex)
            b:ClearAllPoints(); b:SetPoint("RIGHT", card, "LEFT", -6 - n * (CARD_H - 2), 0)
            if b.SetAttribute and not (InCombatLockdown and InCombatLockdown()) then
                b:SetAttribute("type1", "macro")
                b:SetAttribute("macrotext1", "/use " .. tostring(rawget(card, "weapon")) .. "\n/use " .. slot)
            end
            b:Show(); n = n + 1
        else
            b:Hide()
        end
    end
end

local function makeCard(i)
    local card = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate")
    card:SetSize(CARD_W, CARD_H)
    card:SetPoint("TOP", frame, "TOP", 0, -((i - 1) * (CARD_H + GAP)))
    -- the secure template fires on mouse down or up depending on the game setting
    -- (ActionButtonUseKeyDown), so the button has to listen to both
    card:RegisterForClicks("AnyUp", "AnyDown")
    card.skin = makeSkin(card)
    card.skin.anchor = card
    place(card.skin, 0, 0)
    -- cards with more to say show it on hover (decision 237): tipLines = { "line", { "left", "right" }, ... }
    card:SetScript("OnEnter", function(self)
        local lines = rawget(self, "tipLines")
        if not (lines and GameTooltip) then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        for i, l in ipairs(lines) do
            if type(l) == "table" then GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 0.8, 0.8, 0.8)
            elseif i == 1 then GameTooltip:SetText(l)
            else GameTooltip:AddLine(l, 0.8, 0.8, 0.8, true) end
        end
        GameTooltip:Show()
    end)
    card:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- PostClick: the secure template handles the click itself (buff cards cast
    -- their spell); this part only dismisses and starts the guidance.
    card:SetScript("PostClick", function(self, button, down)
        if down then return end          -- the up part of a click does the work
        if moveMode then return end
        -- right click: away; shift + right click: snooze for 5 minutes (decision 328)
        if button == "RightButton" then
            if self.key then
                M:Dismiss(self.key, true, IsShiftKeyDown and IsShiftKeyDown() or false)
            end
            return
        end
        -- a weapon oil or stone: the click shows the worn weapons next to the card (decision 291)
        if rawget(self, "weapon") and button ~= "RightButton" then
            self.wShow = not self.wShow
            M.RefreshWeapons(self)
            return
        end
        -- a drink card is not dismissed either: it vanishes while drinking (decision 219)
        if rawget(self, "useItem") and button ~= "RightButton" then return end
        -- a buff card is not dismissed by the cast: it vanishes once the buff is on
        if self.cast and button ~= "RightButton" then
            -- diagnostics: the secure cast needs these attributes
            if self.GetAttribute and self:GetAttribute("type1") ~= "spell" then
                OMQ:Print("buff click: no cast attribute set (" .. tostring(self.cast) .. ")")
            end
            return
        end
        -- a card that opens a window (the talent tree, decision 234): the click opens it and the card
        -- goes away for the usual 5 minutes (decision 235), like a dismissed card
        if rawget(self, "open") and button ~= "RightButton" then
            -- "keep": the action solves the cause itself, the card goes when the rule no longer sees it
            if self.open() == "keep" then
                if M.Evaluate then M:Evaluate() end
                return
            end
        end
        local go = self.go
        if self.key then M:Dismiss(self.key, false) end
        -- a left click starts the arrow, unless another arrow is already active
        if go and OMQ.Guide and not OMQ.Guide:IsActive()
            and not (OMQ.Arrow and OMQ.Arrow.IsStragglerShown and OMQ.Arrow:IsStragglerShown()) then
            OMQ.Guide:Start(go)
        end
    end)
    card:Hide()
    return card
end

-- ghosts: plain copies that play the way out of a card that is gone
local ghosts = {}
local function ghostFor(i)
    local g = ghosts[i]
    if not g then
        g = makeSkin(frame)
        g.anchor = cards[i]
        g:Hide()
        ghosts[i] = g
    end
    return g
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestAlerts", UIParent)
    frame:SetSize(CARD_W, MAX_CARDS * (CARD_H + GAP) + 18)
    frame:SetFrameStrata("HIGH")
    frame:SetScale(CARD_SCALE)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if moveMode then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition() end)

    cards = {}
    for i = 1, MAX_CARDS do cards[i] = makeCard(i) end
    M._cards = cards
    M.cards = cards
    moreText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    moreText:SetPoint("TOP", frame, "TOP", 0, -(MAX_CARDS * (CARD_H + GAP)) - 1)
    moreText:SetTextColor(0.6, 0.63, 0.68)
    applyPosition()
    frame:SetAlpha(0)
    frame:Hide()
end

local DEMO = {
    { key = "demo1", text = "Alert frame: drag me to a new position", tag = "MOVE MODE", icon = "Interface\\Icons\\INV_Misc_Note_01", color = { 0.89, 0.71, 0.29 } },
}

local slotKey = {}             -- what each slot showed at the last render
local justDismissed = {}       -- key -> true: clicked away (the rest that vanish were solved)
M._slotKey = slotKey

function M:Render()
    if not frame then return end
    -- in combat the frame is hidden (decision 52) and its secure cards must not change; the combat end renders again
    if locked() then return end
    local list = moveMode and DEMO or self:GetActive()
    local was = {}
    for i = 1, MAX_CARDS do if slotKey[i] then was[slotKey[i]] = i end end
    local now = {}
    for i = 1, MAX_CARDS do
        local a, card = list[i], cards[i]
        if a then
            now[a.key] = i
            if card.key ~= a.key then card.wShow = false end
            card.key = a.key
            card.go = a.go or false
            card.cast = a.cast or false
            card.useItem = (not a.weapon) and a.useItem or false
            card.weapon = a.weapon and a.useItem or false
            card.open = a.open or false
            card.tipLines = a.tipLines or false
            if card.SetAttribute and not (InCombatLockdown and InCombatLockdown()) then
                if a.cast and not moveMode then
                    card:SetAttribute("type1", "spell")
                    card:SetAttribute("spell1", a.cast)
                    card:SetAttribute("unit1", a.unit or "player")
                elseif a.useItem and not a.weapon and not moveMode then
                    -- a click uses an item from the bags, e.g. the best drink (decision 219)
                    card:SetAttribute("type1", "item")
                    card:SetAttribute("item1", a.useItem)
                else
                    card:SetAttribute("type1", nil)
                end
            end
            fill(card.skin, a)
            card:Show()
            M.RefreshWeapons(card)
            local j = was[a.key]
            if not j then
                -- a new card: in from the right with the gold shine (and the soft sound)
                tween(card.skin, { x = 26, a = 0 }, { x = 0, a = 1 }, IN_TIME)
                fx(card.skin, "shine")
                if not moveMode and not inCombat and not atAuction and not a.quiet and OMQ.Sound then OMQ.Sound:Play("in") end
            elseif j ~= i then
                -- the stack closes up: from the old place to the new one
                tween(card.skin, { y = -(j - i) * (CARD_H + GAP), a = 1 }, { y = 0, a = 1 }, MOVE_TIME)
            end
            slotKey[i] = a.key
        else
            card.key = nil
            card.go = false
            card.cast = false
            card.open = false
            card.weapon, card.wShow = false, false
            M.RefreshWeapons(card)
            if card.SetAttribute and not (InCombatLockdown and InCombatLockdown()) then card:SetAttribute("type1", nil) end
            card:Hide()
            slotKey[i] = nil
        end
    end
    -- cards that are gone and not just pushed down below the third: play their way out
    for key, j in pairs(was) do
        if not now[key] and not active[key] then
            local old = cards[j]
            local g = ghostFor(j)
            local shown = old and old.skin and old.skin.shown
            if shown then
                fill(g, { title = shown.title, sub = shown.sub, tag = shown.tag, color = shown.color, icon = shown.icon })
                g:Show()
                if justDismissed[key] then
                    tween(g, { x = 0, a = 1 }, { x = 30, a = 0 }, OUT_TIME, 0, function(s) s:Hide() end)
                else
                    fx(g, "glow")
                    tween(g, { x = 0, a = 1 }, { x = 0, a = 0 }, SOLVED_TIME, 0.12, function(s) s:Hide() end)
                end
            end
        end
    end
    justDismissed = {}
    if #list > MAX_CARDS then
        moreText:SetText("+" .. (#list - MAX_CARDS) .. " more")
    else
        moreText:SetText("")
    end
    -- show when there is something to show; hidden in combat (decision 52) and at the auction house (decision 261)
    local visible = #list > 0 and (moveMode or (not inCombat and not atAuction))
    targetAlpha = visible and 1 or 0
    if visible then frame:Show() end
end

function M:_MarkDismissed(key) justDismissed[key] = true end
function M:AtAuction() return atAuction end

local ahWatch = CreateFrame("Frame")
pcall(ahWatch.RegisterEvent, ahWatch, "AUCTION_HOUSE_SHOW")
pcall(ahWatch.RegisterEvent, ahWatch, "AUCTION_HOUSE_CLOSED")
ahWatch:SetScript("OnEvent", function(_, event)
    atAuction = (event == "AUCTION_HOUSE_SHOW")
    -- open cards close at once (no fade) and come back when the auction house closes (decision 262)
    if atAuction and frame then alpha, targetAlpha = 0, 0; frame:SetAlpha(0); if not locked() then frame:Hide() end end
    if M.Evaluate then M:Evaluate() end
end)

local function fade(_, elapsed)
    stepTweens()
    if not frame then return end
    if alpha ~= targetAlpha then
        if targetAlpha > alpha then alpha = math.min(alpha + FADE_SPEED * elapsed, 1)
        else alpha = math.max(alpha - FADE_SPEED * elapsed, 0) end
        frame:SetAlpha(alpha)
        if alpha == 0 and not locked() then frame:Hide() end
    elseif alpha == 0 and frame:IsShown() and not locked() then
        frame:Hide()          -- invisible cards must not catch mouse clicks
    end
end

function M:SetMoveMode(on)
    moveMode = on and true or false
    if frame and not locked() then
        frame:EnableMouse(moveMode)
        -- the cards sit on top of the frame and would swallow the drag
        for _, card in ipairs(cards) do card:EnableMouse(not moveMode) end
    end
    self:Render()
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:SetScript("OnEvent", function(_, event)
    inCombat = (event == "PLAYER_REGEN_DISABLED")
    -- the lockdown starts right after this event: hide the cards at once (a fade would end in combat)
    if inCombat and frame and not locked() then alpha, targetAlpha = 0, 0; frame:SetAlpha(0); frame:Hide() end
    if inCombat then M:Render() else M:SetMoveMode(moveMode) end      -- catches up what waited for the combat end
    OMQ:Fire("ALERT_COMBAT", inCombat)
end)
driver:SetScript("OnUpdate", fade)

OMQ:On("DB_READY", function()
    OMQ.db.alerts = OMQ.db.alerts or {}
    OMQ.db.alerts.enabled = OMQ.db.alerts.enabled or {}
end)

OMQ:On("READY", function()
    build()
    inCombat = InCombatLockdown and InCombatLockdown() or false
    C_Timer.NewTicker(EVAL_INTERVAL, function() M:Evaluate() end)
end)

OMQ:On("MOVE_MODE", function(on) M:SetMoveMode(on) end)

OMQ:RegisterCommand("alerts", function(arg)
    local cmd, value = (arg or ""):match("^(%S*)%s*(.-)$")
    if cmd == "snooze" then
        local minutes = tonumber(value) or 30
        OMQ.db.options.snoozeUntil = time() + minutes * 60
        M:Evaluate()
        OMQ:Print("alerts snoozed for " .. minutes .. " minutes")
    elseif cmd == "unsnooze" then
        OMQ.db.options.snoozeUntil = 0
        OMQ:Print("alerts are on again")
    elseif cmd == "on" or cmd == "off" then
        local id = value
        if not M.rules[id] then
            OMQ:Print("unknown alert. Known: " .. table.concat(M.ruleOrder, ", "))
            return
        end
        OMQ.db.alerts.enabled[id] = (cmd == "on")
        M:Evaluate()
        OMQ:Print("alert " .. id .. " " .. cmd)
    elseif cmd == "ranks" then
        OMQ.db.alerts.lenientRank = (value == "lenient")
        M:Evaluate()
        OMQ:Print(OMQ.db.alerts.lenientRank and "rank alert: any rank of a spell on a bar is fine"
            or "rank alert: the highest learned rank must be on a bar")
    elseif cmd == "position" then
        M:ResetPosition()
        OMQ:Print("alert position reset")
    elseif cmd == "reset" then
        M:ResetDismissed()
        OMQ:Print("all dismissed alerts may appear again")
    else
        OMQ:Print("alerts" .. (M:IsSnoozed() and " (snoozed)" or "") .. ":")
        for _, id in ipairs(M.ruleOrder) do
            local rule = M.rules[id]
            print(string.format("  %-10s %-4s %s", id, M:IsRuleEnabled(id) and "on" or "off", rule.name or ""))
        end
        for _, a in ipairs(M:GetActive()) do print("  active: " .. a.text) end
        for id, why in pairs(M.unavailable or {}) do print("  cannot check " .. id .. ": " .. why) end
        print("  /omq alerts on|off <id> | snooze [minutes] | unsnooze | ranks strict|lenient | reset (brings back dismissed cards)")
    end
end, "alert switches, snooze, status")
