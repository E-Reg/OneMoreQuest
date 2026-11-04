-- One More Quest: match window, invitation and the start button in the ledger's duels tab
-- Reads Stats/Match.lua. Phases: pick (three foes), call (the caller names a value), reveal (my foe big on
-- the left, the others on the right: one as big as mine, two or three stacked, four in a 2x2 grid), result
-- and the end with the points. Foes show their 3D model when the client knows it, else an icon of their type.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local W = {}
OMQ.MatchUI = W
local M = OMQ.Match

local WIDTH, HEIGHT, HEAD, FOOT, PAD = 720, 500, 60, 56, 16
local BODY = HEIGHT - HEAD - FOOT
local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil
local EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local TITLE_FONT, BODY_FONT = "Fonts\\MORPHEUS.TTF", "Fonts\\FRIZQT__.TTF"
local GOLD = { .91, .78, .4 }
local WIN = { .12, 1, 0 }
local NEXT = { 1, .5, 0 }
local PLAIN = { .79, .73, .61 }
local DIM = { .45, .41, .31 }
local EDGE_PLAIN = { .45, .36, .2 }
local RANK_COLOR = { normal = { 1, 1, 1 }, rare = { .29, .64, 1 }, elite = { .91, .78, .4 }, rareelite = { .74, .45, 1 }, boss = { 1, .5, 0 } }
local RANK_NAME = { normal = "Normal", rare = "Rare", elite = "Elite", rareelite = "Rare Elite", boss = "Boss" }
local TYPE_NAME = { beast = "Beast", humanoid = "Humanoid", undead = "Undead", demon = "Demon", elemental = "Elemental",
                    dragonkin = "Dragonkin", giant = "Giant", mechanical = "Mechanical", critter = "Critter", aberration = "Aberration" }
local I = "Interface\\Icons\\"
local TYPE_ICON = { beast = "Ability_Hunter_Pet_Wolf", humanoid = "INV_Misc_Bandana_03", undead = "Spell_Shadow_RaiseDead",
                    demon = "Spell_Shadow_SummonImp", elemental = "Spell_Fire_Elemental_Totem", dragonkin = "INV_Misc_Head_Dragon_01",
                    giant = "Ability_Warrior_Cleave", mechanical = "INV_Gizmo_01", critter = "Ability_Hunter_Pet_Crab" }

local function mmss(s) s = math.max(0, math.floor(s)); return string.format("%d:%02d", math.floor(s / 60), s % 60) end
local function font(fs, file, size)
    if fs.SetFont then pcall(fs.SetFont, fs, file, size, "") end
    return fs
end
local function tex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer)
    if r then t:SetColorTexture(r, g, b, a or 1) end
    return t
end
local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end
local function boxed(f, r, g, b)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = EDGE, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropColor(r or .14, g or .105, b or .07, 1)
        f:SetBackdropBorderColor(EDGE_PLAIN[1], EDGE_PLAIN[2], EDGE_PLAIN[3], 1)
    else
        f.bg = tex(f, "BACKGROUND", r or .14, g or .105, b or .07, 1); f.bg:SetAllPoints()
    end
end
local function setEdge(f, c) if f.SetBackdropBorderColor then f:SetBackdropBorderColor(c[1], c[2], c[3], 1) end end
local function hex(c) return string.format("%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255)) end

-- the tooltip of a value: what it means, and whether it was already played
function W:StatTip(owner, stat)
    local s = M.byStat[stat or ""]
    if not (s and GameTooltip) then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(s.name, GOLD[1], GOLD[2], GOLD[3])
    GameTooltip:AddLine(s.desc or s.hint, 1, 1, 1, true)
    local c = M.cur
    if c and c.used and c.used[stat] then GameTooltip:AddLine("Already played in this duel.", .6, .6, .6, true) end
    GameTooltip:Show()
end
local function hideTip() if GameTooltip then GameTooltip:Hide() end end

function W:ValueText(stat, v)
    v = tonumber(v) or 0
    if stat == "daring" and v > 0 then return "+" .. v end
    return tostring(v)
end

function W:Info(rec)
    local parts = {}
    if (rec.level or 0) > 0 then parts[#parts + 1] = "Level " .. rec.level end
    if TYPE_NAME[rec.type or ""] then parts[#parts + 1] = TYPE_NAME[rec.type] end
    parts[#parts + 1] = RANK_NAME[rec.rank or "normal"] or "Normal"
    if rec.zone and rec.zone ~= "" then parts[#parts + 1] = rec.zone end
    return table.concat(parts, " - ")
end

----------------------------------------------------------------------
-- A foe: 3D model (or type icon), name, info, value. tall: model on top; wide: model on the left
----------------------------------------------------------------------
W.models = { ok = 0, miss = 0 }

local function mobView(parent, w, h, tall, ratio)
    local v = CreateFrame("Frame", nil, parent, BACKDROP)
    v:SetSize(w, h)
    boxed(v)
    v.w, v.h, v.tall = w, h, tall
    v.dad = font(v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
    v.dad:SetPoint("TOPLEFT", 10, -8)
    v.tag = font(v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
    v.tag:SetPoint("TOPRIGHT", -10, -8)
    v.art = tex(v, "ARTWORK", .07, .05, .03, 1)
    local s
    if tall then
        s = math.floor(h * (ratio or 0.48))
        v.art:SetPoint("TOPLEFT", 10, -24); v.art:SetPoint("TOPRIGHT", -10, -24); v.art:SetHeight(s)
    else
        s = math.min(h - 32, math.floor(w * 0.4))
        v.art:SetPoint("TOPLEFT", 10, -24); v.art:SetSize(s, s)
    end
    v.artSize = s
    v.model = CreateFrame("PlayerModel", nil, v)
    v.model:SetPoint("TOPLEFT", v.art, "TOPLEFT"); v.model:SetPoint("BOTTOMRIGHT", v.art, "BOTTOMRIGHT")
    v.icon = v:CreateTexture(nil, "OVERLAY")
    local is = math.floor(s * 0.6)
    v.icon:SetSize(is, is); v.icon:SetPoint("CENTER", v.art, "CENTER")
    v.name = font(v:CreateFontString(nil, "OVERLAY", tall and "GameFontNormalLarge" or "GameFontNormal"), TITLE_FONT, tall and 18 or 14)
    v.info = font(v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, tall and 11 or 10)
    if tall then
        v.name:SetPoint("TOPLEFT", v.art, "BOTTOMLEFT", 0, -8); v.name:SetWidth(w - 20)
        v.info:SetPoint("TOPLEFT", v.name, "BOTTOMLEFT", 0, -4); v.info:SetWidth(w - 20)
    else
        v.name:SetPoint("TOPLEFT", v.art, "TOPRIGHT", 10, 0); v.name:SetWidth(w - s - 30)
        v.info:SetPoint("TOPLEFT", v.name, "BOTTOMLEFT", 0, -4); v.info:SetWidth(w - s - 30)
    end
    v.name:SetJustifyH("LEFT"); v.info:SetJustifyH("LEFT")
    -- the value box at the bottom
    v.valBg = tex(v, "ARTWORK", .07, .05, .03, 1)
    v.valBg:SetPoint("BOTTOMRIGHT", -10, 10)
    if tall then v.valBg:SetPoint("BOTTOMLEFT", 10, 10) else v.valBg:SetPoint("BOTTOMLEFT", 20 + s, 10) end
    v.valBg:SetHeight(tall and 46 or 32)
    v.label = font(v:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, tall and 13 or 11)
    v.label:SetPoint("LEFT", v.valBg, "LEFT", 10, 0)
    v.value = font(v:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"), TITLE_FONT, tall and 30 or 22)
    v.value:SetPoint("RIGHT", v.valBg, "RIGHT", -10, 0)
    v.valHit = CreateFrame("Frame", nil, v)
    v.valHit:SetAllPoints(v.valBg)
    v.valHit:EnableMouse(true)
    v.valHit:SetScript("OnEnter", function(self) W:StatTip(self, v.statId) end)
    v.valHit:SetScript("OnLeave", hideTip)
    v.valHit:Hide()
    v.facing = 0
    v:SetScript("OnUpdate", function(self, dt)
        if self.model:IsShown() and self.model.SetFacing then
            self.facing = (self.facing + (dt or 0) * 0.6) % (2 * math.pi)
            pcall(self.model.SetFacing, self.model, self.facing)
        end
    end)
    return v
end
W._MobView = mobView

-- the 3D model by creature id; when the client does not know it, the icon of its type
local function setMob(v, rec)
    v.icon:SetTexture(I .. (TYPE_ICON[rec.type or ""] or "INV_Misc_QuestionMark"))
    local c = RANK_COLOR[rec.rank or "normal"] or RANK_COLOR.normal
    v.name:SetText(rec.name or "?"); v.name:SetTextColor(c[1], c[2], c[3])
    v.info:SetText(W:Info(rec)); color(v.info, PLAIN)
    if v.mobId == rec.id then return end
    v.mobId = rec.id
    v.model:Hide(); v.icon:Show()
    if not (rec.id and v.model.SetCreature) then return end
    local fine = pcall(v.model.SetCreature, v.model, rec.id)
    if not fine then return end
    if v.model.SetPortraitZoom then pcall(v.model.SetPortraitZoom, v.model, 0) end
    if v.model.SetCamDistanceScale then pcall(v.model.SetCamDistanceScale, v.model, 1.15) end
    v.model:Show(); v.icon:Hide()
    local id = rec.id
    C_Timer.After(0.6, function()
        if v.mobId ~= id then return end
        local file = v.model.GetModelFileID and select(2, pcall(v.model.GetModelFileID, v.model))
        if type(file) == "number" and file > 0 then
            W.models.ok = W.models.ok + 1
        else
            W.models.miss = W.models.miss + 1
            v.model:Hide(); v.icon:Show()
        end
    end)
end
W._SetMob = setMob

local function setValue(v, stat, value, c)
    local s = M.byStat[stat or ""]
    v.statId = s and s.id
    if not s then v.valBg:Hide(); v.valHit:Hide(); v.label:SetText(""); v.value:SetText(""); return end
    v.valBg:Show(); v.valHit:Show()
    v.label:SetText(s.name); color(v.label, PLAIN)
    v.value:SetText(value ~= nil and W:ValueText(stat, value) or "?")
    color(v.value, c or PLAIN)
end
W._SetValue = setValue

----------------------------------------------------------------------
-- The window
----------------------------------------------------------------------
local function button(parent, w, h, text)
    local b = CreateFrame("Button", nil, parent, BACKDROP)
    b:SetSize(w, h)
    boxed(b, .07, .05, .03)
    setEdge(b, { .54, .43, .18 })
    b.label = font(b:CreateFontString(nil, "OVERLAY", "GameFontNormal"), BODY_FONT, 12)
    b.label:SetPoint("CENTER")
    b.label:SetText(text or "")
    return b
end

local function build()
    local f = CreateFrame("Frame", "OneMoreQuestMatch", UIParent, BACKDROP)
    W.frame = f
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    boxed(f, .11, .086, .063)
    setEdge(f, { .54, .43, .18 })
    f.head = tex(f, "BORDER", .15, .114, .075, 1)
    f.head:SetPoint("TOPLEFT", 4, -4); f.head:SetPoint("TOPRIGHT", -4, -4); f.head:SetHeight(HEAD - 4)
    f.portrait = f:CreateTexture(nil, "ARTWORK")
    f.portrait:SetSize(40, 40); f.portrait:SetPoint("TOPLEFT", 14, -10)
    f.portrait:SetTexture(I .. "Ability_Warrior_Challange")
    f.title = font(f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 20)
    f.title:SetPoint("TOPLEFT", f.portrait, "TOPRIGHT", 12, -2)
    f.title:SetText("Dad Duel")
    color(f.title, GOLD)
    f.sub = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
    f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.close = CreateFrame("Button", nil, f)
    f.close:SetSize(28, 28); f.close:SetPoint("TOPRIGHT", -10, -14)
    local cx = f.close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cx:SetPoint("CENTER"); cx:SetText("x"); color(cx, PLAIN)
    f.close:SetScript("OnClick", function() W:Close() end)
    f.close:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(M:Active() and "Leave the duel" or "Close")
        GameTooltip:Show()
    end)
    f.close:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f.timer = font(f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 18)
    f.timer:SetPoint("TOPRIGHT", f.close, "TOPLEFT", -14, 0)
    color(f.timer, GOLD)
    f.barBg = tex(f, "ARTWORK", .23, .18, .09, 1)
    f.barBg:SetSize(110, 5); f.barBg:SetPoint("TOPRIGHT", f.timer, "BOTTOMRIGHT", 0, -4)
    f.bar = tex(f, "OVERLAY", .78, .64, .29, 1)
    f.bar:SetHeight(5); f.bar:SetPoint("TOPLEFT", f.barBg, "TOPLEFT")

    -- footer: the current results
    f.foot = tex(f, "BORDER", .15, .114, .075, 1)
    f.foot:SetPoint("BOTTOMLEFT", 4, 4); f.foot:SetPoint("BOTTOMRIGHT", -4, 4); f.foot:SetHeight(FOOT - 4)
    f.footLine = tex(f, "ARTWORK", .54, .43, .18, 1)
    f.footLine:SetPoint("BOTTOMLEFT", 4, FOOT); f.footLine:SetPoint("BOTTOMRIGHT", -4, FOOT); f.footLine:SetHeight(1)
    f.resHead = font(f:CreateFontString(nil, "OVERLAY", "GameFontNormal"), TITLE_FONT, 15)
    f.resHead:SetPoint("BOTTOM", 0, 31); f.resHead:SetText("Current Results:"); color(f.resHead, GOLD)
    f.results = font(f:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 13)
    f.results:SetPoint("BOTTOM", 0, 11)
    f.results:SetJustifyH("CENTER")
    if f.results.SetWordWrap then f.results:SetWordWrap(false) end

    local function pane()
        local p = CreateFrame("Frame", nil, f)
        p:SetPoint("TOPLEFT", 0, -HEAD); p:SetSize(WIDTH, BODY)
        p:Hide()
        return p
    end

    -- waiting (invitation running)
    f.waitPane = pane()
    f.waitText = font(f.waitPane:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 14)
    f.waitText:SetPoint("TOP", 0, -60); f.waitText:SetWidth(WIDTH - 80)

    -- pick: three foes and the dads beside them
    f.pickPane = pane()
    local side = 156
    local cw = math.floor((WIDTH - 2 * PAD - side - 3 * 10) / 3)
    f.offers = {}
    for i = 1, M.OFFERS do
        local v = mobView(f.pickPane, cw, BODY - 20, true, 0.34)
        v:SetPoint("TOPLEFT", PAD + (i - 1) * (cw + 10), -10)
        v.valBg:Hide()
        -- the whole card is the button
        v.hit = CreateFrame("Button", nil, v)
        v.hit:SetAllPoints(v)
        if v.hit.SetFrameLevel and v.GetFrameLevel then v.hit:SetFrameLevel((v:GetFrameLevel() or 1) + 2) end
        v.hit:RegisterForClicks("LeftButtonUp")
        v.hit:SetScript("OnClick", function() W:PickCard(i) end)
        v.hit:SetScript("OnEnter", function() W:HoverCard(i, true) end)
        v.hit:SetScript("OnLeave", function() W:HoverCard(i, false) end)
        v.glow = tex(v, "BACKGROUND", 1, .85, .45, .07)
        v.glow:SetPoint("TOPLEFT", 3, -3); v.glow:SetPoint("BOTTOMRIGHT", -3, 3)
        v.glow:Hide()
        v.state = font(v:CreateFontString(nil, "OVERLAY", "GameFontNormal"), TITLE_FONT, 15)
        v.state:SetPoint("BOTTOM", 0, 14)
        v.rows = {}
        for k, s in ipairs(M.STATS) do
            local l = font(v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 10)
            l:SetPoint("TOPLEFT", v.info, "BOTTOMLEFT", 0, -8 - (k - 1) * 13)
            local r = font(v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 10)
            r:SetPoint("TOPRIGHT", v.info, "BOTTOMRIGHT", 0, -8 - (k - 1) * 13)
            l:SetText(s.name)
            -- each value row explains itself on hover and still picks the card on click
            local h = CreateFrame("Button", nil, v.hit)
            h:SetPoint("TOPLEFT", l, "TOPLEFT", -2, 2)
            h:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 2, -1)
            h:RegisterForClicks("LeftButtonUp")
            h.stat = s.id
            h:SetScript("OnClick", function() W:PickCard(i) end)
            h:SetScript("OnEnter", function(self) W:HoverCard(i, true); W:StatTip(self, self.stat) end)
            h:SetScript("OnLeave", function() hideTip(); W:HoverCard(i, false) end)
            v.rows[k] = { l = l, r = r, stat = s.id, hit = h }
        end
        f.offers[i] = v
    end
    f.side = CreateFrame("Frame", nil, f.pickPane, BACKDROP)
    f.side:SetSize(side, BODY - 20); f.side:SetPoint("TOPRIGHT", -PAD, -10)
    boxed(f.side, .09, .067, .043)
    f.sideHead = font(f.side:CreateFontString(nil, "OVERLAY", "GameFontNormal"), TITLE_FONT, 14)
    f.sideHead:SetPoint("TOPLEFT", 10, -10); f.sideHead:SetText("Dads"); color(f.sideHead, GOLD)
    f.sideRows = {}
    for i = 1, M.MAX_PLAYERS do
        local n = font(f.side:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
        n:SetPoint("TOPLEFT", 10, -36 - (i - 1) * 22)
        local s = font(f.side:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
        s:SetPoint("TOPRIGHT", -10, -36 - (i - 1) * 22)
        f.sideRows[i] = { n = n, s = s }
    end
    f.sideNote = font(f.side:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 10)
    f.sideNote:SetPoint("BOTTOMLEFT", 10, 10); f.sideNote:SetWidth(side - 20)
    f.sideNote:SetJustifyH("LEFT")
    if f.sideNote.SetSpacing then f.sideNote:SetSpacing(2) end

    -- call: my foe and the eight values
    f.callPane = pane()
    f.callMine = mobView(f.callPane, 290, BODY - 20, true)
    f.callMine:SetPoint("TOPLEFT", PAD, -10)
    f.callHead = font(f.callPane:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 17)
    f.callHead:SetPoint("TOPLEFT", PAD + 290 + 20, -16); f.callHead:SetWidth(WIDTH - 2 * PAD - 310)
    f.callHead:SetJustifyH("LEFT")
    f.statBtns = {}
    local bw = math.floor((WIDTH - 2 * PAD - 310 - 10) / 2)
    for i, s in ipairs(M.STATS) do
        local b = button(f.callPane, bw, 46, "")
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        b:SetPoint("TOPLEFT", PAD + 310 + col * (bw + 10), -50 - row * 54)
        b.label:ClearAllPoints(); b.label:SetPoint("TOPLEFT", 10, -8); b.label:SetText(s.name)
        b.hint = font(b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 9)
        b.hint:SetPoint("BOTTOMLEFT", 10, 8); b.hint:SetText(s.hint); b.hint:SetWidth(bw - 60); b.hint:SetJustifyH("LEFT")
        b.val = font(b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 20)
        b.val:SetPoint("RIGHT", -10, 0)
        b.stat = s.id
        b:SetScript("OnClick", function(self) M:Call(self.stat) end)
        f.statBtns[i] = b
    end

    -- reveal: mine on the left, the others on the right
    f.revealPane = pane()
    f.views = {}
    f.vs = font(f.revealPane:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"), TITLE_FONT, 24)
    f.vs:SetText("VS"); color(f.vs, { .54, .43, .18 })

    -- the end
    f.donePane = pane()
    f.doneHead = font(f.donePane:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"), TITLE_FONT, 24)
    f.doneHead:SetPoint("TOP", 0, -24)
    f.doneRows = {}
    for i = 1, M.MAX_PLAYERS do
        local row = CreateFrame("Frame", nil, f.donePane, BACKDROP)
        row:SetSize(420, 36); row:SetPoint("TOP", 0, -70 - (i - 1) * 42)
        boxed(row, .09, .067, .043)
        row.place = font(row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 18)
        row.place:SetPoint("LEFT", 12, 0)
        row.name = font(row:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), BODY_FONT, 14)
        row.name:SetPoint("LEFT", 44, 0)
        row.pts = font(row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 20)
        row.pts:SetPoint("RIGHT", -14, 0)
        f.doneRows[i] = row
    end
    f.doneBtn = button(f.donePane, 140, 32, "Close")
    f.doneBtn:SetPoint("BOTTOMRIGHT", -PAD, 10)
    f.doneBtn:SetScript("OnClick", function() W:Close() end)
    f:Hide()
end

-- the reveal views for n others (created once per layout)
local function revealViews(n)
    local f = W.frame
    if f.views[n] then return f.views[n] end
    local set = { others = {} }
    local h = BODY - 20
    local mineW = n == 1 and 320 or 290
    set.mine = mobView(f.revealPane, mineW, h, true)
    set.mine:SetPoint("TOPLEFT", PAD, -10)
    if n == 1 then
        local v = mobView(f.revealPane, mineW, h, true)
        v:SetPoint("TOPRIGHT", -PAD, -10)
        set.others[1] = v
    else
        local x0 = PAD + mineW + 16
        local aw = WIDTH - PAD - x0
        if n <= 3 then
            local vh = math.floor((h - (n - 1) * 8) / n)
            for i = 1, n do
                local v = mobView(f.revealPane, aw, vh, false)
                v:SetPoint("TOPLEFT", x0, -10 - (i - 1) * (vh + 8))
                set.others[i] = v
            end
        else
            local vw, vh = math.floor((aw - 8) / 2), math.floor((h - 8) / 2)
            for i = 1, 4 do
                local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
                local v = mobView(f.revealPane, vw, vh, false)
                v:SetPoint("TOPLEFT", x0 + col * (vw + 8), -10 - row * (vh + 8))
                set.others[i] = v
            end
        end
    end
    set.n = n
    f.views[n] = set
    return set
end
W._RevealViews = revealViews

----------------------------------------------------------------------
-- Painting
----------------------------------------------------------------------
-- the class of a dad: me from my own client, the others from what the group told us
function W:ClassOf(p)
    local me = OMQ:GetSelf()
    if me and p.guid == me.guid then return me.class end
    local u = OMQ.users and OMQ.users[p.guid]
    return u and u.class
end

local function classHex(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c then return hex({ c.r, c.g, c.b }) end
    return hex({ .91, .87, .78 })
end

function W:ResultsText(c)
    local parts = {}
    for _, p in ipairs(c.players) do
        local pts = (p.score or 0) == 1 and "1 Point" or ((p.score or 0) .. " Points")
        if p.left then
            parts[#parts + 1] = "|cff777777" .. p.name .. ": " .. pts .. " (left)|r"
        else
            parts[#parts + 1] = "|cff" .. classHex(self:ClassOf(p)) .. p.name .. "|r: |cffffffff" .. pts .. "|r"
        end
    end
    return table.concat(parts, "   |cff8a6e2e|||r   ")
end

local function showPane(name)
    local f = W.frame
    for _, k in ipairs({ "waitPane", "pickPane", "callPane", "revealPane", "donePane" }) do
        if k == name then f[k]:Show() else f[k]:Hide() end
    end
end

local function setTimer(left, total)
    local f = W.frame
    if not left then f.timer:SetText(""); f.barBg:Hide(); f.bar:Hide(); return end
    f.timer:SetText(mmss(left))
    f.barBg:Show(); f.bar:Show()
    f.bar:SetWidth(math.max(1, 110 * math.min(1, left / math.max(1, total))))
end

local function roundText(c)
    if c.round > M.ROUNDS then return "Extra round " .. (c.round - M.ROUNDS) end
    return "Round " .. c.round .. " of " .. M.ROUNDS
end

function W:SetResults(text)
    local f = self.frame
    -- one line over the whole width: a smaller font when five long names do not fit
    for _, size in ipairs({ 13, 12, 11, 10 }) do
        font(f.results, BODY_FONT, size)
        f.results:SetText(text or "")
        local w = f.results.GetStringWidth and f.results:GetStringWidth()
        if type(w) ~= "number" or w <= WIDTH - 2 * PAD then break end
    end
    if text then f.resHead:Show() else f.resHead:Hide() end
end

-- a card lights up under the mouse while it can be picked
W.hover = {}
function W:PaintCard(i)
    local f, c = self.frame, M.cur
    local v = f and f.offers[i]
    if not (v and c) then return end
    local id = c.offers and c.offers[i]
    local chosen = id ~= nil and c.choice == id
    local open = c.phase == "pick"
    local lit = open and self.hover[i]
    setEdge(v, (chosen or lit) and GOLD or EDGE_PLAIN)
    if v.SetBackdropColor then
        if lit then v:SetBackdropColor(.2, .155, .1, 1) else v:SetBackdropColor(.14, .105, .07, 1) end
    end
    if lit then v.glow:Show() else v.glow:Hide() end
    if chosen then v.state:SetText("Picked"); color(v.state, GOLD)
    elseif lit then v.state:SetText("Click to pick"); color(v.state, GOLD)
    else v.state:SetText("") end
end

function W:HoverCard(i, on)
    self.hover[i] = on or nil
    self:PaintCard(i)
end

function W:PickCard(i)
    local c = M.cur
    if not (c and c.phase == "pick") then return end
    M:Pick(i)
end

local function paintPick(c)
    local f = W.frame
    showPane("pickPane")
    local picked = c.phase ~= "pick"
    for i, v in ipairs(f.offers) do
        local id = c.offers and c.offers[i]
        local mob = id and M:Mob(id)
        if mob then
            v:Show()
            setMob(v, mob)
            v.dad:SetText(""); v.tag:SetText("")
            for _, r in ipairs(v.rows) do
                r.r:SetText(W:ValueText(r.stat, mob.vals[r.stat]))
                local col = c.used[r.stat] and DIM or { .91, .87, .78 }
                color(r.l, col); color(r.r, col)
            end
            W:PaintCard(i)
        else
            v:Hide()
        end
    end
    for i, row in ipairs(f.sideRows) do
        local p = c.players[i]
        if p then
            row.n:SetText(p.name); color(row.n, i == c.me and GOLD or PLAIN)
            if p.left then row.s:SetText("left"); color(row.s, DIM)
            elseif not M:InRound(i) then row.s:SetText("watches"); color(row.s, DIM)
            elseif c.picks[c.round][i] then row.s:SetText("picked"); color(row.s, WIN)
            else row.s:SetText("choosing"); color(row.s, PLAIN) end
        else
            row.n:SetText(""); row.s:SetText("")
        end
    end
    local caller = c.players[c.caller]
    f.sideNote:SetText("Goes on as soon as everybody has picked. After 30 seconds a random foe is picked.\n\n"
        .. (c.caller == c.me and "You call the value this round." or (tostring(caller and caller.name) .. " calls the value this round.")))
    f.sub:SetText(roundText(c) .. " - " .. (picked and "waiting for the others" or "pick your foe. The others see it when it is revealed."))
end

local function paintCall(c)
    local f = W.frame
    showPane("callPane")
    local mob = c.choice and M:Mob(c.choice)
    if mob then
        setMob(f.callMine, mob)
        f.callMine.dad:SetText("Your foe"); color(f.callMine.dad, PLAIN)
        f.callMine.tag:SetText("")
        f.callMine.valBg:Hide(); f.callMine.label:SetText(""); f.callMine.value:SetText("")
        f.callMine:Show()
    else
        f.callMine:Hide()
    end
    local mine = c.caller == c.me and c.phase == "call"
    local caller = c.players[c.caller]
    if mine then
        f.callHead:SetText("Which value?"); color(f.callHead, GOLD)
    elseif c.phase == "watch" then
        local names = {}
        for _, i in ipairs(M:RoundPlayers()) do names[#names + 1] = c.players[i].name end
        f.callHead:SetText("Extra round: " .. table.concat(names, " vs ")); color(f.callHead, PLAIN)
    else
        f.callHead:SetText(tostring(caller and caller.name) .. " is calling a value ..."); color(f.callHead, PLAIN)
    end
    for _, b in ipairs(f.statBtns) do
        b.val:SetText(mob and W:ValueText(b.stat, mob.vals[b.stat]) or "")
        local used = c.used[b.stat]
        if mine and not used then
            b:Enable(); color(b.label, { .91, .87, .78 }); color(b.val, GOLD); color(b.hint, PLAIN); setEdge(b, { .54, .43, .18 })
            b.hint:SetText(M.byStat[b.stat].hint)
        else
            b:Disable(); color(b.label, DIM); color(b.val, DIM); color(b.hint, DIM); setEdge(b, { .2, .16, .09 })
            b.hint:SetText(used and "already played" or M.byStat[b.stat].hint)
        end
    end
    f.sub:SetText(roundText(c) .. (mine and " - you call the value" or ""))
end

local function paintReveal(c)
    local f = W.frame
    showPane("revealPane")
    local r = c.round
    local res = c.results[r]
    local others = {}
    for i in ipairs(c.players) do if i ~= c.me and (M:InRound(i) or (c.reveals[r] and c.reveals[r][i])) then others[#others + 1] = i end end
    local n = math.max(1, math.min(4, #others))
    for k, set in pairs(f.views) do
        if k ~= n then set.mine:Hide(); for _, v in ipairs(set.others) do v:Hide() end end
    end
    local set = revealViews(n)
    local function paintOne(v, i)
        local p = c.players[i]
        local rec = c.reveals[r] and c.reveals[r][i]
        v:Show()
        v.dad:SetText(i == c.me and "You" or p.name); color(v.dad, PLAIN)
        if rec then
            setMob(v, rec)
            local col = PLAIN
            if res and res.winners[i] then col = WIN end
            setValue(v, c.stat, rec.value, col)
        else
            v.mobId = nil
            v.model:Hide(); v.icon:Show(); v.icon:SetTexture(I .. "INV_Misc_QuestionMark")
            v.name:SetText(p.left and "left the duel" or "..."); color(v.name, DIM)
            v.info:SetText("")
            setValue(v, c.stat, nil, DIM)
        end
        v.tag:SetText("")
        setEdge(v, EDGE_PLAIN)
        if res then
            if res.winners[i] then v.tag:SetText("+1 point"); color(v.tag, WIN); setEdge(v, WIN)
            elseif res.caller == i and not res.final then v.tag:SetText("calls next"); color(v.tag, NEXT) end
        end
    end
    if M:InRound(c.me) or (c.reveals[r] and c.reveals[r][c.me]) then paintOne(set.mine, c.me) else set.mine:Hide() end
    for k, v in ipairs(set.others) do
        if others[k] then paintOne(v, others[k]) else v:Hide() end
    end
    if n == 1 then f.vs:ClearAllPoints(); f.vs:SetPoint("CENTER", f.revealPane, "CENTER", 0, 0); f.vs:Show() else f.vs:Hide() end
    local s = M.byStat[c.stat or ""]
    local caller = c.players[c.caller]
    f.sub:SetText(roundText(c) .. " - " .. (s and s.name or "?") .. " - called by " .. tostring(caller and caller.name))
end

local function paintDone(c)
    local f = W.frame
    showPane("donePane")
    local leaders = M:Leaders()
    local names = {}
    for _, i in ipairs(leaders) do names[#names + 1] = c.players[i].name end
    if #leaders == 1 then f.doneHead:SetText(names[1] .. " wins the duel")
    else f.doneHead:SetText("Shared win: " .. table.concat(names, ", ")) end
    color(f.doneHead, GOLD)
    local order = {}
    for i in ipairs(c.players) do order[#order + 1] = i end
    table.sort(order, function(a, b)
        if c.players[a].score ~= c.players[b].score then return c.players[a].score > c.players[b].score end
        return a < b
    end)
    local place, last = 0, nil
    for k, row in ipairs(f.doneRows) do
        local i = order[k]
        if i then
            local p = c.players[i]
            if p.score ~= last then place = k; last = p.score end
            row.place:SetText(tostring(place))
            row.name:SetText(p.name .. (p.left and " (left)" or ""))
            row.pts:SetText(tostring(p.score))
            local col = place == 1 and GOLD or PLAIN
            color(row.place, col); color(row.pts, col); color(row.name, i == c.me and GOLD or { .91, .87, .78 })
            row:Show()
        else
            row:Hide()
        end
    end
    f.sub:SetText((c.round > M.ROUNDS and "after extra rounds - " or "") .. #c.players .. " dads" .. (c.demo and " - demo" or ""))
    setTimer(nil)
end

function W:Refresh()
    local f = self.frame
    if not f then return end
    local c = M.cur
    if not c then
        if M.waiting then
            showPane("waitPane")
            f.waitText:SetText("Waiting for " .. tostring(M.waiting.hostName) .. " to start the duel ...")
            f.sub:SetText("Dad Duel - 5 rounds")
            W:SetResults(nil)
            setTimer(M.waiting.deadline - GetTime(), M.INVITE_TIME)
        end
        return
    end
    self:SetResults(c.phase ~= "invite" and self:ResultsText(c) or nil)
    if c.phase == "invite" then
        showPane("waitPane")
        local parts = {}
        for g, name in pairs(c.asked) do
            local a = c.answers[g]
            parts[#parts + 1] = name .. (a and (a.yes and " - in" or " - no") or " - ...")
        end
        table.sort(parts)
        f.waitText:SetText("Waiting for the dads:\n\n" .. table.concat(parts, "\n"))
        f.sub:SetText("Dad Duel - 5 rounds")
        setTimer(c.deadline - GetTime(), M.INVITE_TIME)
        return
    end
    local calling = c.callRound == c.round
    if c.phase == "pick" or ((c.phase == "picked" or c.phase == "watch") and not calling) then
        paintPick(c)
        setTimer(c.phaseAt + M.PICK_TIME - GetTime(), M.PICK_TIME)
    elseif c.phase == "call" or c.phase == "watch" or c.phase == "picked" then
        paintCall(c)
        setTimer(c.callAt and (c.callAt + M.CALL_TIME - GetTime()) or nil, M.CALL_TIME)
    elseif c.phase == "reveal" or c.phase == "result" then
        paintReveal(c)
        setTimer(nil)
    elseif c.phase == "done" then
        paintDone(c)
    end
end

function W:Show()
    if not self.frame then build() end
    self.frame:Show()
    self:Refresh()
end

-- the X: out of the match, or just closed at the end
function W:Close()
    if M.cur then M:Leave() end
    M.waiting = nil
    self.hover = {}
    if self.frame then self.frame:Hide() end
end

OMQ:On("MATCH_UPDATE", function()
    if M.cur or M.waiting then
        if not (W.frame and W.frame:IsShown()) then W:Show() else W:Refresh() end
    elseif W.frame and W.frame:IsShown() then
        W.frame:Hide()
    end
    if W.popup and W.popup:IsShown() and not M.invite then W.popup:Hide() end
end)

----------------------------------------------------------------------
-- The invitation
----------------------------------------------------------------------
local function buildPopup()
    local p = CreateFrame("Frame", "OneMoreQuestMatchInvite", UIParent, BACKDROP)
    W.popup = p
    p:SetSize(320, 130)
    p:SetPoint("TOP", 0, -160)
    p:SetFrameStrata("DIALOG")
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    boxed(p, .11, .086, .063)
    setEdge(p, { .54, .43, .18 })
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(36, 36); p.icon:SetPoint("TOPLEFT", 14, -14)
    p.icon:SetTexture(I .. "Ability_Warrior_Challange")
    p.title = font(p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), TITLE_FONT, 16)
    p.title:SetPoint("TOPLEFT", p.icon, "TOPRIGHT", 10, -2); p.title:SetWidth(250); p.title:SetJustifyH("LEFT")
    color(p.title, GOLD)
    p.text = font(p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), BODY_FONT, 11)
    p.text:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -4)
    p.text:SetText("Dad Duel, 5 rounds. Pick your foes, beat their values.")
    p.barBg = tex(p, "ARTWORK", .23, .18, .09, 1)
    p.barBg:SetPoint("TOPLEFT", 14, -62); p.barBg:SetPoint("TOPRIGHT", -14, -62); p.barBg:SetHeight(5)
    p.bar = tex(p, "OVERLAY", .78, .64, .29, 1)
    p.bar:SetPoint("TOPLEFT", p.barBg, "TOPLEFT"); p.bar:SetHeight(5)
    p.yes = button(p, 140, 32, "Accept")
    p.yes:SetPoint("BOTTOMLEFT", 14, 14)
    p.yes:SetScript("OnClick", function() M:Answer(true); p:Hide() end)
    p.no = button(p, 140, 32, "Decline")
    p.no:SetPoint("BOTTOMRIGHT", -14, 14)
    p.no:SetScript("OnClick", function() M:Answer(false); p:Hide() end)
    p:SetScript("OnUpdate", function(self)
        local inv = M.invite
        if not inv then self:Hide(); return end
        local left = math.max(0, inv.deadline - GetTime())
        self.bar:SetWidth(math.max(1, 292 * left / M.INVITE_TIME))
    end)
    p:Hide()
end

OMQ:On("MATCH_INVITE", function(inv)
    if not W.popup then buildPopup() end
    W.popup.title:SetText(tostring(inv.hostName) .. " challenges you")
    W.popup:Show()
    if OMQ.Sound and OMQ.Sound.Play then pcall(OMQ.Sound.Play, OMQ.Sound, "popup") end
end)

----------------------------------------------------------------------
-- Test command (not in /omq help): demo against simulated dads, start, diagnostics
----------------------------------------------------------------------
OMQ:RegisterCommand("match", function(arg)
    local cmd, rest = (arg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "demo" then
        local fine, why = M:Demo(tonumber(rest) or 1)
        if not fine then OMQ:Print("match demo: " .. tostring(why)) end
        return
    end
    if cmd == "diag" then
        local keys = {}
        for k, v in pairs(M.diag) do keys[#keys + 1] = k .. "=" .. v end
        table.sort(keys)
        OMQ:Print("match: unlocked " .. tostring(M:Unlocked()) .. ", foes " .. #M:Pool() .. ", models " .. W.models.ok
            .. " shown / " .. W.models.miss .. " as icon, " .. table.concat(keys, " "))
        return
    end
    if cmd == "start" then
        local fine, why = M:Challenge()
        if not fine then OMQ:Print("duel: " .. tostring(why)) end
        return
    end
    if M.cur or M.waiting then W:Show() else OMQ:Print("match: demo [1-4] | start | diag") end
end, nil, true)
