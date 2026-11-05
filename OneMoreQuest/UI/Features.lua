-- One More Quest: "List functionality" (decision 247)
-- A plain list of everything the addon does, the big things first. No explanation of where or how:
-- just bullet points, grouped under headings (decision 257; brought up to date with group Crafting in decision 352). Opened from the button at the bottom right of the
-- full options window.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local FE = {}
OMQ.Features = FE

-- Grouped by what the dads do with it (decision 257); the most important group first, and in each group the
-- big things first. FE.LIST is the same content as one flat list.
FE.SECTIONS = {
    { "Playing together", {
        "One more quest: when the vote (/omq) says \"One more quest!\", the arrow leads the group to the next quest every dad has - its objectives, or the turn-in once all are done; no quest in common: a new one everybody can take",
        "Group statistics for the session, ranked between the dads: XP per hour, levels, gold, yards walked and yards on follow, damage share, killing blows, deaths, near deaths, fights started and more",
        "Lifetime statistics of every dad's character",
        "Quests are shared and accepted automatically between dads up to 5 levels apart",
        "Catch Up for the dad who fell behind: every quest the dads have and you lack, what is missing for each one (level, quest chain, class, faction, an item you need) and the level that opens it; works in the group and alone, from the last picture of the group",
        "Group quest tracker: every dad's progress on shared quests",
        "Meeting point and map pin shared with the group",
        "Item score in every item tooltip, for you and for every dad: what each one wears and whether the item is an upgrade for his class and role",
        "Follow the flights of the group",
        "Follow key for the nearest dad",
        "Mana break note when a dad drinks",
    } },
    { "Dungeons", {
        "Group Check before a dungeon: durability, bags, drinks, class items, distance to the entrance",
        { "Dungeon quests of every dad, where each quest starts, with an arrow to the quest giver and the rewards scored for you", unlock = "dungeon" },
        { "Best boss loot of a dungeon for you, also for the new Forever dungeons", unlock = "dungeon" },
        { "Threat meter: everybody's threat on your target, in every group or only in dungeons; as the tank you see who pulls the aggro off you", unlock = "threat" },
        { "Arrow to the dungeon entrance, with how to get in", unlock = "dungeon" },
        { "Switch between the dungeons of your level in the Group Check", unlock = "dungeon" },
        "Progress Check: the milestones of your class, the dungeons and, on request, the quest zones by level; a click on a zone leads to its quest hub",
    } },
    { "Finding your way", {
        "Distance arrow to dads who fell behind",
        "Arrows to class and profession trainers, vendors, repair, flight masters, mailboxes, inns, banks, auction houses, map pins, the meeting point and your corpse",
        "Places the dads visit are learned and shared, also in the new Forever zones",
    } },
    { "Alert cards", {
        "Train new skills, with what is new and what it costs, also right after a level up",
        "Spells not on an action bar, placed with one click",
        "Dungeon quests you could still take, when you leave a town, a city or a flight master",
        "Missing buffs, auras, shields, armors, imbues and poisons, cast with one click",
        "Repair, also before you leave a city or take a flight",
        "Buy drinks, and a reminder to drink when your mana is low; mages conjure water with one click instead",
        "Profession training and the tool a profession needs",
        "Find Minerals and Find Herbs switched on with one click",
        "Pet basics: hunters call, revive and feed their pet, warlocks summon one of their last three demons",
        "Unspent talent points, opens the talent tree",
        "Low ammo",
        "Use your elixirs, scrolls, buff food, stones and oils - never, always or in dungeons; a stone or oil goes on the weapon you click",
    } },
    { "Crafting", {
        { "Crafting profit in the profession window: what the materials cost against what the product brings on the auction house, for every recipe", unlock = "profession" },
        { "Cheapest skill-up: two badges mark the cheapest recipe to skill up, by cost and by profit, and every recipe shows its skill-up chance", unlock = "profession" },
        { "Prices of the whole auction house in one scan, plus the vendor prices you have seen; every item tooltip shows the latest price", unlock = "auction" },
        { "Who in the group needs a crafting material, and who carries the materials of a recipe", unlock = "profession" },
    } },
    { "Fun between the dads", {
        { "Bets between the dads, decided automatically, debts paid by mail", unlock = "bets" },
        "\"One more quest?\" vote, with titles for the session at bed time",
    } },
    { "Healing and click casting", {
        "Shift-click heals for healers on the party frames",
        "Click casting on your own resource display, also when solo",
    } },
    { "Comfort", {
        "Quests at the NPC: accepted (not the grey ones), finished ones handed in, the best reward marked by item score",
        { "Auction helper: everything worth more on the auction house, posted with one click each - fast or select mode; it starts with a scan of the whole auction house", unlock = "auction" },
        { "Auction helper, buy mode: weapon upgrades, potions, elixirs, stones, oils, scrolls, buff food and armor kits, bags, reagent bags and quivers for your class - stock up or buy single pieces", unlock = "auction" },
        "Vendor helper: what to sell at the vendor - grey items, gear not worth the auction house or unsold twice, old food and drink, recipes of professions you do not have",
        "Automatic repair, selling of grey items, water and ammo at vendors",
        "Dad UI: the shared interface of the dads with one click, per character; your old UI can be restored",
        "Chat filter, with a window for the hidden messages",
        "Hide the objective tracker",
        "Sounds for the alerts and the tracker",
        "Guided tour",
    } },
}
-- an entry is a text, or { text, unlock = id }: a feature that is not open yet is left out (UI/Unlock.lua)
local function visible()
    local out = {}
    for _, sec in ipairs(FE.SECTIONS) do
        local list = {}
        for _, e in ipairs(sec[2]) do
            if type(e) == "string" then list[#list + 1] = e
            elseif not (e.unlock and OMQ.Unlock and not OMQ.Unlock:Has(e.unlock)) then list[#list + 1] = e[1] end
        end
        if #list > 0 then out[#out + 1] = { sec[1], list } end
    end
    return out
end
FE.Visible = visible
FE.LIST = {}
local function listNow()
    FE.LIST = {}
    for _, sec in ipairs(visible()) do
        for _, t in ipairs(sec[2]) do FE.LIST[#FE.LIST + 1] = t end
    end
end
listNow()

local GOLD = { 0.89, 0.71, 0.29 }
local frame

local function build()
    frame = CreateFrame("Frame", "OneMoreQuestFeatures", UIParent)
    frame:SetSize(560, 520)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    if frame.RegisterForDrag then frame:RegisterForDrag("LeftButton") end
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0.07, 0.08, 0.105, 0.97)
    frame.edge = frame:CreateTexture(nil, "BORDER")
    frame.edge:SetPoint("TOPLEFT"); frame.edge:SetPoint("TOPRIGHT"); frame.edge:SetHeight(3)
    frame.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -18)
    title:SetText("One More Quest - Functionality")
    local close = CreateFrame("Button", nil, frame)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -6, -8)
    local cx = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cx:SetPoint("CENTER"); cx:SetText("x"); cx:SetTextColor(0.55, 0.58, 0.63)
    close:SetScript("OnClick", function() frame:Hide() end)

    local sf = CreateFrame("ScrollFrame", "OneMoreQuestFeaturesScroll", frame, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 16, -50)
    sf:SetPoint("BOTTOMRIGHT", -34, 16)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(500, 10)
    sf:SetScrollChild(content)
    -- per group: a gold heading with a thin line under it, then the points with a gold bullet (decision 257).
    -- Each heading hangs below the group before it, so the game does the spacing however the lines wrap.
    local W = 500
    frame.heads, frame.bodies = {}, {}
    local prev
    listNow()
    for i, sec in ipairs(visible()) do
        local h = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        if prev then h:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", -10, -18) else h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0) end
        h:SetText(sec[1])
        h:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        local cnt = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        cnt:SetPoint("BOTTOMRIGHT", h, "BOTTOMLEFT", W, 0)
        cnt:SetText(#sec[2] == 1 and "1 feature" or (#sec[2] .. " features"))
        local line = content:CreateTexture(nil, "ARTWORK")
        line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
        line:SetSize(W, 1)
        line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
        local lines = {}
        for _, t in ipairs(sec[2]) do lines[#lines + 1] = "|cffe3b54a\226\128\162|r  " .. t end    -- a gold bullet
        local body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        body:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 10, -11)
        body:SetWidth(W - 10)
        body:SetJustifyH("LEFT")
        if body.SetSpacing then body:SetSpacing(4) end
        body:SetText(table.concat(lines, "\n"))
        frame.heads[i], frame.bodies[i] = h, body
        prev = body
    end
    -- the scroll height: measured once the window is on screen (an estimate until then)
    content:SetHeight(#FE.LIST * 34 + #frame.heads * 40)
    frame:SetScript("OnShow", function()
        local top, bottom = content:GetTop(), prev:GetBottom()
        top, bottom = tonumber((top)), tonumber((bottom))
        if top and bottom and top > bottom then content:SetHeight(top - bottom + 10) end
    end)
    if UISpecialFrames then table.insert(UISpecialFrames, "OneMoreQuestFeatures") end
    frame:Hide()
end

function FE:Show() if not frame then build() end; frame:Show() end
function FE:Toggle()
    if frame and frame:IsShown() then frame:Hide() else FE:Show() end
end
function FE:Frame() return frame end

-- a feature opened: the list is drawn anew the next time
OMQ:On("UNLOCK", function()
    if not frame then listNow(); return end
    local open = frame:IsShown()
    frame:Hide()
    frame = nil
    listNow()
    if open then FE:Show() end
end)

OMQ:RegisterCommand("features", function() FE:Toggle() end, "list everything the addon does")
