-- One More Quest: check bar. A second small icon bar that hangs above the guidance bar (it moves with
-- it and is shown with it). Collapsed it shows only the Group Check button; hovering it slides out
-- the others (the group vote of /omq). Same behaviour as the guidance bar, same growth direction.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local SIZE, GAP, PAD = 34, 3, 4        -- 20 % larger than before (decision 193)

local CB = {}
OMQ.CheckBar = CB
CB.COLLAPSED = 1                       -- only the Group Check is always shown (decision 302: no One more quest icon)

local frame, buttons = nil, {}       -- buttons[id] = button (created once)
local items = {}                      -- the items shown now: fixed ones, then the dungeons for my level
local expanded, suppressed = false, false
local flipped = false

-- icons in the "engraved stone" style (decision 192), rendered into Media
local MEDIA = "Interface\\AddOns\\OneMoreQuest\\Media\\"
local ITEMS = {
    { id = "ready", label = "Group Check", tip = "Click: durability, bags, drinks and class items of the group",
      icon = MEDIA .. "Icon_Check" },
    { id = "vote", label = "Group vote (/omq)", tip = "Click: start a vote - One more quest! (the arrow then leads the group to the next quest) or Bed time",
      icon = MEDIA .. "Icon_Vote" },
    { id = "bet", label = "Bet Check", tip = "Click: start a bet with the dads",          -- decision 170
      icon = MEDIA .. "Icon_Bet" },
    { id = "progress", label = "Progress Check", tip = "Click: your milestone timeline, from level 1 to 60",   -- decision 184
      icon = MEDIA .. "Icon_Progress" },
    { id = "rhythm", label = "Spell Rhythm", tip = "Click: press your spell keys to the beat of a song",   -- decision 381, from level 30
      icon = MEDIA .. "Icon_Rhythm", show = function() return OMQ.Rhythm and OMQ.Rhythm:Unlocked() end },
}

local pendingLevel
local function currentItems()
    local list = {}
    for _, it in ipairs(ITEMS) do if not it.show or it.show() then list[#list + 1] = it end end
    local level = math.max(UnitLevel and UnitLevel("player") or 1, pendingLevel or 0)   -- UnitLevel can lag behind PLAYER_LEVEL_UP
    if OMQ.DungeonsForLevel then
        for _, d in ipairs(OMQ:DungeonsForLevel(level)) do
            list[#list + 1] = { id = "d:" .. d.key, label = d.name, dungeon = d.key, text = d.abbr,
                tip = "Click: Group Check with the dungeon quests, the entrance and who is how far from it (level " .. d.min .. "-" .. d.max .. ")" }
        end
    end
    return list
end

local makeButton

local function layout()
    if not frame then return end
    items = currentItems()
    local n = expanded and #items or CB.COLLAPSED
    local guide = OMQ.GuideBar and OMQ.GuideBar:Frame()
    frame:ClearAllPoints()
    if guide then
        if flipped then frame:SetPoint("BOTTOMRIGHT", guide, "TOPRIGHT", 0, 2)
        else frame:SetPoint("BOTTOMLEFT", guide, "TOPLEFT", 0, 2) end
    end
    frame:SetSize(PAD * 2 + n * (SIZE + GAP) - GAP, SIZE + PAD * 2)
    local used = {}
    for i, it in ipairs(items) do
        local b = buttons[it.id] or makeButton(it)
        used[it.id] = true
        if i <= n then
            local slot = flipped and (n - i) or (i - 1)
            b:ClearAllPoints()
            b:SetPoint("LEFT", frame, "LEFT", PAD + slot * (SIZE + GAP), 0)
            b:Show()
        else
            b:Hide()
        end
    end
    for id, b in pairs(buttons) do if not used[id] then b:Hide() end end
end

local function click(item)
    if item.id == "ready" then
        OMQ.Ready:Toggle()
    elseif item.dungeon then
        OMQ.Ready:Toggle(item.dungeon)
    elseif item.id == "vote" then
        if OMQ.Vote then OMQ.Vote:Start() end
    elseif item.id == "bet" then
        if OMQ.BetUI then OMQ.BetUI:ToggleCreate() end
    elseif item.id == "progress" then
        if OMQ.Milestones then OMQ.Milestones:Toggle() end
    elseif item.id == "rhythm" then
        if OMQ.Rhythm then
            local _, why = OMQ.Rhythm:Open("bar")
            if why == "combat" then OMQ:Print("Spell Rhythm: not in combat.") end
        end
    end
    suppressed = true
    expanded = false
    layout()
end

local function mouseOver()
    if frame.IsMouseOver then
        local ok, v = pcall(frame.IsMouseOver, frame)
        if ok then return v and true or false end
    end
    return MouseIsOver and MouseIsOver(frame) and true or false
end

function makeButton(item)
    local b = CreateFrame("Button", nil, frame)
    buttons[item.id] = b
    b:SetSize(SIZE, SIZE)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    if item.icon then
        b.icon:SetTexture(item.icon)
    else
        b.icon:SetTexture(MEDIA .. "Icon_Dungeon")             -- dungeon buttons: the short name engraved on stone
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.label:SetPoint("CENTER", 0, -1)
        if b.label.SetFont then pcall(b.label.SetFont, b.label, "Fonts\\MORPHEUS.TTF", 13, "OUTLINE") end
        b.label:SetText(item.text or "?")
        b.label:SetTextColor(0.94, 0.78, 0.38)
    end
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.item = item
    b:SetScript("OnClick", function(self) click(self.item) end)
    b:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.item.label)
        GameTooltip:AddLine(self.item.tip, 0.8, 0.8, 0.8)
        if self.item.id == "bet" and OMQ.Bets and OMQ.Bets.FillTooltip then pcall(OMQ.Bets.FillTooltip, OMQ.Bets, GameTooltip) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return b
end

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestCheckBar", UIParent)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    local plate = frame:CreateTexture(nil, "BACKGROUND")
    plate:SetAllPoints()
    plate:SetColorTexture(0.07, 0.08, 0.105, 0.92)
    local t = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        t = t + (elapsed or 0)
        if t < 0.05 then return end
        t = 0
        local over = mouseOver()
        if not over then suppressed = false end
        local want = CB.tourOpen or (over and not suppressed)          -- tourOpen: the guided tour (decision 244)
        if want ~= expanded then expanded = want; layout() end
    end)
    layout()
end

-- follows the guidance bar: same visibility, same side
local function follow(guide, isFlipped)
    if not frame then return end
    flipped = isFlipped and true or false
    if guide and guide:IsShown() then frame:Show() else frame:Hide() end
    layout()
end

function CB:IsExpanded() return expanded end
function CB:Count()                    -- the fixed items available now (Spell Rhythm from level 30)
    local n = 0
    for _, it in ipairs(ITEMS) do if not it.show or it.show() then n = n + 1 end end
    return n
end
function CB:Items() return items end
function CB:Refresh() layout() end
function CB:Button(id) return buttons[id] end

local lvl = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD" }) do pcall(lvl.RegisterEvent, lvl, e) end
lvl:SetScript("OnEvent", function(_, e, newLevel)
    if e == "PLAYER_LEVEL_UP" then pendingLevel = tonumber(newLevel) end
    if frame then layout() end
end)

OMQ:On("READY", function()
    build()
    if OMQ.GuideBar then
        OMQ.GuideBar.onLayout = follow
        local g = OMQ.GuideBar:Frame()
        if g then follow(g, OMQ.GuideBar:IsFlipped()) end
    end
end)
