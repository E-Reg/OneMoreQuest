-- One More Quest: the best boss loot of a dungeon for me, in the Group Check (decision 233)
-- Every boss item of the dungeon (Data/DungeonLoot.lua) is scored against what I wear, with the
-- item score of my class and preferred role (Score.lua, decision 200). Items my class cannot wear or
-- wield (decision 214) and items without a slot are left out. The three biggest upgrades are shown
-- as tiles: the real icon with a quality border, the name in its quality colour, the score and the
-- slot. Hover: the game's own item tooltip. Click: like any item (Shift links it, Ctrl tries it on).
-- Names, icons, slots and stats all come from the game, so they are in the client's language.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local LP = {}
OMQ.LootPreview = LP

LP.COUNT = 3
LP.MIN_W = 560                   -- the Group Check is at least this wide when the tiles are shown
local TILE_H, ICON, GAP = 52, 38, 8
local HEAD_H = 20

local function SC() return OMQ.Score end
local function isSecret(v) return issecretvalue and issecretvalue(v) end

local function info(id)
    if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(id) end
    if GetItemInfo then return GetItemInfo(id) end
end
local function instant(id)
    if C_Item and C_Item.GetItemInfoInstant then return C_Item.GetItemInfoInstant(id) end
    if GetItemInfoInstant then return GetItemInfoInstant(id) end
end
local function request(id)
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
end

-- all item IDs of a dungeon, each once, with the boss NPC that drops it
function LP.Items(key)
    local out, seen = {}, {}
    for _, boss in ipairs((OMQ.DungeonLoot or {})[key] or {}) do
        for i = 2, #boss do
            local id = boss[i]
            if not seen[id] then seen[id] = true; out[#out + 1] = { id = id, npc = boss[1] } end
        end
    end
    return out
end

-- the score of an item against my gear: the best slot it can go into (for rings and trinkets the
-- weaker one is replaced, an empty slot counts the full value); a two-hander replaces both hands
function LP.Gain(link, equipLoc, class, role, wornOf)
    local S = SC()
    local slots = OMQ.Compare and OMQ.Compare.SLOTS and OMQ.Compare.SLOTS[equipLoc or ""]
    if not (S and slots) then return nil end
    -- without a class the score knows no weights and every item scored 0 (decision 294): mine by default
    class = class or (S.MyClass and S.MyClass())
    role = role or (S.MyRole and S.MyRole())
    wornOf = wornOf or function(slot) return GetInventoryItemLink and GetInventoryItemLink("player", slot) end
    -- two-hander against both hands, no off-hand next to a two-hander (decision 285)
    local best
    for _, slot in ipairs(slots) do
        local d = S.HandDelta(link, equipLoc, wornOf(slot), wornOf(16), wornOf(17), class, role)
        if d and (not best or d > best) then best = d end
    end
    -- a one-hander for a dad who fights with two weapons (a weapon in the off hand) may replace the off-hand one too (decision 402)
    if equipLoc == "INVTYPE_WEAPON" then
        local oh = wornOf(17)
        local ohLoc = type(oh) == "string" and select(4, instant(oh))
        if ohLoc == "INVTYPE_WEAPON" or ohLoc == "INVTYPE_WEAPONOFFHAND" then
            local d = S.Delta(link, oh, class, role)
            if d and (not best or d > best) then best = d end
        end
    end
    return best
end

-- the best upgrades: list of { id, link, gain, equipLoc, minLevel, quality, icon }, and how many
-- items are still loading
function LP.Best(key, n, class, level, role, wornOf)
    local S = SC()
    if not S then return {}, 0 end
    class = class or S.MyClass()
    level = level or (UnitLevel and UnitLevel("player")) or 1
    role = role or S.MyRole()
    local list, loading = {}, 0
    for _, it in ipairs(LP.Items(key)) do
        local _, _, _, equipLoc = instant(it.id)
        if equipLoc and equipLoc ~= "" and OMQ.Compare and OMQ.Compare.SLOTS[equipLoc] then
            local name, link, quality, ilvl, minLevel, _, _, _, _, icon = info(it.id)
            if not name or not link then
                loading = loading + 1
                request(it.id)
            elseif not isSecret(link) then
                local ok = S.CanUse(link, class, math.max(level, minLevel or 0))
                if ok then
                    local g = LP.Gain(link, equipLoc, class, role, wornOf)
                    if g and g > 0 then
                        list[#list + 1] = { id = it.id, link = link, gain = g, equipLoc = equipLoc, minLevel = minLevel or 0,
                                            quality = quality or 1, icon = icon, ilvl = ilvl or 0, name = name }
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.gain ~= b.gain then return a.gain > b.gain end
        if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
        return a.id < b.id
    end)
    local out = {}
    for i = 1, math.min(n or LP.COUNT, #list) do out[i] = list[i] end
    return out, loading
end

----------------------------------------------------------------------
-- Quest rewards in the quest tooltip of the Group Check (decision 279)
-- The item rewards of a dungeon quest (Data/QuestRewards.lua), scored like the boss loot: an upgrade
-- shows "+N", gear that is no upgrade "no upgrade", gear my class cannot use "not for you", the rest
-- (potions, bags, ...) nothing. Upgrades first.
----------------------------------------------------------------------
function LP.RewardIDs(q)
    local R = OMQ.QuestRewards or {}
    if not q then return nil end
    if R[q.id] then return R[q.id] end
    for _, id in ipairs(q.alt or {}) do if R[id] then return R[id] end end
    return nil
end

-- list of { id, name, link, quality, gain, equipLoc, state = "up" | "no" | "cannot" | "other" }, and how many still load
function LP.Rewards(q, class, level, role, wornOf)
    local ids = LP.RewardIDs(q)
    if not ids then return nil, 0 end
    local S = SC()
    class = class or (S and S.MyClass())
    level = level or (UnitLevel and UnitLevel("player")) or 1
    role = role or (S and S.MyRole())
    local list, loading = {}, 0
    for i, id in ipairs(ids) do
        local name, link, quality, _, minLevel = info(id)
        if not name or not link or isSecret(link) then
            loading = loading + 1
            request(id)
        else
            local _, _, _, equipLoc = instant(id)
            local e = { id = id, name = name, link = link, quality = quality or 1, equipLoc = equipLoc, order = i, minLevel = minLevel or 0 }
            local gear = equipLoc and equipLoc ~= "" and OMQ.Compare and OMQ.Compare.SLOTS and OMQ.Compare.SLOTS[equipLoc]
            if not (gear and S) then e.state = "other"
            elseif not S.CanUse(link, class, math.max(level, minLevel or 0)) then e.state = "cannot"
            else
                e.gain = LP.Gain(link, equipLoc, class, role, wornOf)
                e.state = (e.gain and e.gain > 0) and "up" or "no"
            end
            list[#list + 1] = e
        end
    end
    local rank = { up = 1, no = 2, other = 3, cannot = 4 }
    table.sort(list, function(a, b)
        if rank[a.state] ~= rank[b.state] then return rank[a.state] < rank[b.state] end
        if (a.gain or 0) ~= (b.gain or 0) then return (a.gain or 0) > (b.gain or 0) end
        return a.order < b.order
    end)
    return list, loading
end

local function rewardColor(q)
    if C_Item and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(q)
        if r then return r, g, b end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- adds the reward lines to the GameTooltip; true when there were rewards
function LP:AddRewardLines(tip, q, owner)
    local list, loading = LP.Rewards(q)
    if not list then return false end
    local S = SC()
    local role = S and S.MyRole() or "damage"
    tip:AddLine(" ")
    tip:AddLine("Rewards  |cff9aa0aa(item score, " .. ((S and S.ROLE_LABEL and S.ROLE_LABEL[S.RoleOf(S.MyClass(), role) or role]) or role) .. ")|r")
    for _, e in ipairs(list) do
        local r, g, b = rewardColor(e.quality)
        local slot = (e.equipLoc and e.equipLoc ~= "" and _G[e.equipLoc]) or ""
        local right
        if e.state == "up" then right = "|cff40e060+" .. e.gain .. "|r"
        elseif e.state == "no" then right = "|cff9aa0aano upgrade|r"
        elseif e.state == "cannot" then right = "|cff9aa0aanot for you|r"
        else right = "" end
        if slot ~= "" then right = (right ~= "" and (right .. "  ") or "") .. "|cffc9ccd5" .. slot .. "|r" end
        tip:AddDoubleLine(e.name, right, r, g, b, 1, 1, 1)
    end
    if loading > 0 then
        tip:AddLine("Loading " .. loading .. " item" .. (loading == 1 and "" or "s") .. "...", 0.6, 0.63, 0.68)
        LP.tipOwner = owner                       -- shown again when the items arrive
    end
    return true
end

----------------------------------------------------------------------
-- Tiles
----------------------------------------------------------------------
local head, note, tiles = nil, nil, {}
LP._tiles = tiles

local function qualityColor(q)
    if C_Item and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(q)
        if r then return r, g, b end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function makeTile(parent)
    local t = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    t:SetHeight(TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    t.bg:SetColorTexture(1, 1, 1, 0.04)
    t:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(ICON, ICON)
    t.icon:SetPoint("LEFT", t, "LEFT", 7, 0)
    t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- quality border: four thin lines around the icon
    t.edges = {}
    for i = 1, 4 do t.edges[i] = t:CreateTexture(nil, "OVERLAY") end
    local e = t.edges
    e[1]:SetPoint("TOPLEFT", t.icon, "TOPLEFT", -2, 2); e[1]:SetPoint("TOPRIGHT", t.icon, "TOPRIGHT", 2, 2); e[1]:SetHeight(2)
    e[2]:SetPoint("BOTTOMLEFT", t.icon, "BOTTOMLEFT", -2, -2); e[2]:SetPoint("BOTTOMRIGHT", t.icon, "BOTTOMRIGHT", 2, -2); e[2]:SetHeight(2)
    e[3]:SetPoint("TOPLEFT", t.icon, "TOPLEFT", -2, 2); e[3]:SetPoint("BOTTOMLEFT", t.icon, "BOTTOMLEFT", -2, -2); e[3]:SetWidth(2)
    e[4]:SetPoint("TOPRIGHT", t.icon, "TOPRIGHT", 2, 2); e[4]:SetPoint("BOTTOMRIGHT", t.icon, "BOTTOMRIGHT", 2, -2); e[4]:SetWidth(2)
    t.name = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.name:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 8, 1)
    t.name:SetPoint("RIGHT", t, "RIGHT", -40, 0)
    t.name:SetJustifyH("LEFT")
    t.name:SetJustifyV("TOP")
    t.name:SetHeight(24)
    if t.name.SetWordWrap then t.name:SetWordWrap(true) end
    t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    t.sub:SetPoint("BOTTOMLEFT", t.icon, "BOTTOMRIGHT", 8, -1)
    t.sub:SetPoint("RIGHT", t, "RIGHT", -6, 0)
    t.sub:SetJustifyH("LEFT")
    if t.sub.SetWordWrap then t.sub:SetWordWrap(false) end
    t.gain = t:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t.gain:SetPoint("TOPRIGHT", t, "TOPRIGHT", -7, -6)
    t.gain:SetJustifyH("RIGHT")
    t:RegisterForClicks("AnyUp")
    t:SetScript("OnEnter", function(self)
        if not (GameTooltip and self.link) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.link)       -- the game's own item tooltip
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    t:SetScript("OnClick", function(self)
        if self.link and HandleModifiedItemClick then HandleModifiedItemClick(self.link) end
    end)
    return t
end

function LP:Hide()
    if head then head:Hide(); note:Hide() end
    for _, t in ipairs(tiles) do t:Hide() end
end

-- draws the part into the Group Check at (x, -y) with the given width; returns its height
function LP:Render(parent, key, x, y, width)
    if not head then
        head = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        head:SetJustifyH("LEFT")
        note = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        note:SetJustifyH("LEFT")
    end
    head:ClearAllPoints()
    head:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    head:SetWidth(width)
    local S = SC()
    local role = S and S.MyRole() or "damage"
    head:SetText("Best boss loot for you  |cff9aa0aa(item score, " .. ((S and S.ROLE_LABEL[S.RoleOf(S.MyClass(), role) or role]) or role) .. ")|r")
    head:Show()
    note:ClearAllPoints()
    note:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -(y + HEAD_H))
    note:SetWidth(width)
    local best, loading = {}, 0
    if (OMQ.DungeonLoot or {})[key] then best, loading = LP.Best(key, LP.COUNT) end
    local tw = math.floor((width - GAP * (LP.COUNT - 1)) / LP.COUNT)
    for i = 1, LP.COUNT do
        local t = tiles[i] or makeTile(parent)
        tiles[i] = t
        local b = best[i]
        if b then
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", parent, "TOPLEFT", x + (i - 1) * (tw + GAP), -(y + HEAD_H))
            t:SetWidth(tw)
            t.link = b.link
            t.icon:SetTexture(b.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local r, g, bl = qualityColor(b.quality)
            for _, e in ipairs(t.edges) do e:SetColorTexture(r, g, bl, 1) end
            t.name:SetText(b.name)
            t.name:SetTextColor(r, g, bl)
            t.gain:SetText("|cff40e060+" .. b.gain .. "|r")
            local slot = _G[b.equipLoc] or ""
            local myLevel = UnitLevel and UnitLevel("player") or 1
            if b.minLevel > myLevel then
                t.sub:SetText(slot .. "  |cffff5050level " .. b.minLevel .. "|r")
            else
                t.sub:SetText(slot)
            end
            t:Show()
        else
            t:Hide()
        end
    end
    local text
    if not (OMQ.DungeonLoot or {})[key] then text = "No loot list for this dungeon yet"
    elseif #best == 0 and loading > 0 then text = "Loading the items..."
    elseif #best == 0 then text = "Nothing from the bosses beats your gear"
    elseif loading > 0 then text = "" end
    if text then
        note:SetText(text)
        note:Show()
    else
        note:Hide()
    end
    LP.loading = loading
    if #best == 0 then return HEAD_H + 16 end
    return HEAD_H + TILE_H
end

-- items arrive from the server: draw again (the Group Check redraws everything, at most twice a second)
local pendingRedraw = false
local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
pcall(ev.RegisterEvent, ev, "PLAYER_EQUIPMENT_CHANGED")
ev:SetScript("OnEvent", function(_, event)
    -- a quest tooltip waiting for its reward items (decision 279)
    local o = LP.tipOwner
    if event == "GET_ITEM_INFO_RECEIVED" and o and GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(o) and o.GetScript then
        LP.tipOwner = nil
        local f = o:GetScript("OnEnter")
        if f then pcall(f, o) end
    end
    if event == "GET_ITEM_INFO_RECEIVED" and not (LP.loading and LP.loading > 0) then return end
    if pendingRedraw then return end
    pendingRedraw = true
    C_Timer.After(0.5, function()
        pendingRedraw = false
        local R = OMQ.Ready
        local f = R and R.Frame and R:Frame()
        if f and f:IsShown() and R.dungeon then R:Render() end
    end)
end)
