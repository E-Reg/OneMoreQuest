-- One More Quest: Auction Helper, buy mode (decision 264)
-- The switch on top of the auction helper turns it from selling to buying. It suggests only what fits
-- the class, the role and the level, each with what I carry and what it suggests:
--   weapon upgrades (item score against what I wield, usable up to 2 levels above mine, at most half
--   my gold), healing and mana potions (5 each), elixirs (10), weapon stones for blades or blunt
--   weapons (10), weapon oil (2, it has 5 charges), scrolls (5), buff food (10), armor kits for chest,
--   legs, hands and feet without an enchantment, a shield spike for a shield without one.
-- A buff item found in the bags joins the list: the dad got it himself, so he wants it again.
-- Bags too (decision 265): a bigger bag, profession bags, soul bags, quivers and ammo pouches.
-- Two ways to buy: "Fill up" (a click buys what is missing; one button fills everything, one click per
-- item) and "Single" (a click buys one piece). Right click: never suggest it again. No price brake.
-- A purchase counts at once, even while it waits in the mailbox (decision 271).
-- Buying a commodity: StartCommoditiesPurchase (needs the click), then the price quote comes back and
-- ConfirmCommoditiesPurchase completes it. Single auctions (weapons): PlaceBid with the buyout.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local B = {}
OMQ.AuctionBuy = B

B.TARGET = { potion = 5, scroll = 5, elixir = 10, stone = 10, oil = 2, food = 10, flask = 2, juju = 5, kit = 1, spike = 1 }
B.KIND_LABEL = { potion = "potion", scroll = "scroll", elixir = "elixir", stone = "weapon stone", oil = "weapon oil",
                 food = "buff food", flask = "flask", juju = "juju", kit = "armor kit", spike = "shield spike" }
B.KIND_ORDER = { potion = 1, elixir = 2, flask = 3, food = 4, scroll = 5, stone = 6, oil = 7, kit = 8, spike = 9, juju = 10 }
B.WEAPON_LEVELS, B.WEAPON_GOLD_SHARE, B.WEAPON_ROWS, B.WEAPON_CHECK = 2, 0.5, 3, 5
B.ROWS = 10

local GOLD = { 0.89, 0.71, 0.29 }
local function isSecret(v) return issecretvalue and issecretvalue(v) end
local function now() return GetTime() end
local CA = function() return C_AuctionHouse end
local function AH() return OMQ.AuctionHelper end
local function money(c) return AH().Money(c) end
local function money0(c) return (c and c > 0) and money(c) or "-" end

local function db()
    OMQDB.ah = OMQDB.ah or {}
    OMQDB.ah.never = OMQDB.ah.never or {}
    OMQDB.ah.used = OMQDB.ah.used or {}
    local guid = UnitGUID and UnitGUID("player") or "?"
    OMQDB.ah.used[guid] = OMQDB.ah.used[guid] or {}
    return OMQDB.ah, OMQDB.ah.used[guid]
end
function B.Mode()
    local o = OMQ.db and OMQ.db.options
    return (o and o.ahBuyMode == "single") and "single" or "fill"
end
function B.SetMode(m)
    OMQ.db.options.ahBuyMode = (m == "single") and "single" or "fill"
    AH().Refresh()
end

local function instant(id)
    if C_Item and C_Item.GetItemInfoInstant then return C_Item.GetItemInfoInstant(id) end
    if GetItemInfoInstant then return GetItemInfoInstant(id) end
end
local function info(x)
    if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(x) end
    if GetItemInfo then return GetItemInfo(x) end
end
local function count(id)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, false) or 0 end
    if GetItemCount then return GetItemCount(id) or 0 end
    return 0
end
-- bought at the auction house but still in the mailbox (decision 271): a purchase counts at once
B.MAIL_DAYS = 30
local function mailbox()
    OMQDB.ah = OMQDB.ah or {}
    OMQDB.ah.mail = OMQDB.ah.mail or {}
    local guid = UnitGUID and UnitGUID("player") or "?"
    OMQDB.ah.mail[guid] = OMQDB.ah.mail[guid] or {}
    return OMQDB.ah.mail[guid]
end
local function clock() return (time and time()) or 0 end
-- what I have: in the bags, or bought and on the way (once the bags hold it, the note goes)
function B.Have(id)
    local bags = count(id)
    local m = mailbox()
    local e = m[id]
    if e and (bags >= (e.n or 0) or clock() - (e.t or 0) > B.MAIL_DAYS * 86400) then m[id] = nil; e = nil end
    return e and math.max(bags, e.n) or bags
end
-- the mailbox is open and holds no auction mail with the item any more: it was taken (or used up), the note goes
-- (decision 402) - else a dad who used some of his stock before he went to the mailbox stayed "stocked" for 30 days
B.MAIL_GRACE = 60          -- seconds: the mail of a purchase needs a moment to arrive
function B.CheckMail()
    if not (GetInboxNumItems and GetInboxItem) then return end
    local shown, total = GetInboxNumItems()
    shown = tonumber(shown) or 0
    if total and tonumber(total) and tonumber(total) > shown then return end     -- not every mail is listed: keep the notes
    local inMail = {}
    for i = 1, shown do
        for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
            local ok, _, id = pcall(GetInboxItem, i, a)
            if ok and type(id) == "number" and not isSecret(id) then inMail[id] = true end
        end
    end
    local m = mailbox()
    for id, e in pairs(m) do
        if not inMail[id] and clock() - (e.t or 0) > B.MAIL_GRACE then m[id] = nil end
    end
end
-- base: what I had when I clicked (if the bags already got it, it is not counted twice)
function B.Bought(id, qty, base)
    if not (id and qty and qty > 0) then return end
    local m = mailbox()
    m[id] = { n = (base or B.Have(id)) + qty, t = clock() }
end
local function level() return UnitLevel and tonumber((UnitLevel("player"))) or 1 end

----------------------------------------------------------------------
-- What fits my class and role
----------------------------------------------------------------------
-- the lines of Data/BuyList.lua a class and role use
function B.Lines(class, role)
    local L = { "heal" }
    local mana = class ~= "WARRIOR" and class ~= "ROGUE"
    if mana then L[#L + 1] = "mana" end
    local caster = class == "MAGE" or class == "WARLOCK" or class == "PRIEST" or role == "caster" or role == "heal"
    local tank = role == "tank"
    local function add(...) for _, k in ipairs({ ... }) do L[#L + 1] = k end end
    if caster then
        add("e_int")
        if role ~= "heal" then add("e_spell") end
        add("s_int", "s_spi", "s_sta")
        add(role == "heal" and "oil_mana" or "oil_wiz")
        add("f_mp5")
    elseif tank then
        add("e_def", "e_fort", "s_sta", "s_prot")
        if class == "DRUID" then add("e_agi", "s_agi", "f_agi") else add("s_str", "f_str", "stone") end
    elseif class == "ROGUE" or class == "HUNTER" or class == "DRUID" then
        add("e_agi", "s_agi", "s_sta", "s_prot", "f_agi")
        if class == "ROGUE" then add("stone") end
    else                                                   -- warrior, paladin, shaman with weapons
        add("e_str", "s_str", "s_sta", "s_prot", "f_str", "stone")
        if class == "WARRIOR" then add("e_agi") end
    end
    add("kit", "spike")
    return L
end

-- blade or blunt: which stone the main hand weapon takes
local BLADE = { [0] = true, [1] = true, [6] = true, [7] = true, [8] = true, [15] = true }
local BLUNT = { [4] = true, [5] = true, [10] = true, [13] = true }
function B.StoneLine()
    local link = GetInventoryItemLink and GetInventoryItemLink("player", 16)
    if not link or isSecret(link) then return nil end
    local _, _, _, _, _, classID, subID = instant(link)
    if classID ~= 2 then return nil end
    if BLADE[subID] then return "stone_sharp" end
    if BLUNT[subID] then return "stone_weight" end
    return nil
end

local function enchanted(slot)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
    if not link or isSecret(link) then return nil end
    local e = tonumber(tostring(link):match("item:%d+:(%d*)") or "") or 0
    return e > 0
end
-- armor kits: chest, legs, hands, feet without an enchantment
function B.KitSlots()
    local n = 0
    for _, slot in ipairs({ 5, 7, 10, 8 }) do if enchanted(slot) == false then n = n + 1 end end
    return n
end
function B.ShieldWithoutSpike()
    local link = GetInventoryItemLink and GetInventoryItemLink("player", 17)
    if not link or isSecret(link) then return false end
    local _, _, _, equipLoc = instant(link)
    return equipLoc == "INVTYPE_SHIELD" and enchanted(17) == false
end

-- the best item of a line for my level
-- buffs that do not stack (decision 284)
-- 1. a class that buffs the same stat itself needs no consumable for it (Arcane Intellect, Power Word:
--    Fortitude, Divine Spirit); only once it knows the spell
B.CLASS_BUFFS = {
    MAGE   = { { lines = { "s_int" }, spells = { 1459, 1460, 1461, 10156, 10157 } } },     -- the elixirs stack with it
    PRIEST = { { lines = { "s_sta" }, spells = { 1243, 1244, 1245, 2791, 10937, 10938 } },
               { lines = { "s_spi" }, spells = { 14752, 14818, 14819, 27841 } } },
}
-- 2. consumables that do not stack with each other: once one of them is in stock (or bought and on
--    its way), the others are not suggested
B.EXCLUSIVE = { { "e_def", "s_prot" } }
local function knowsSpell(id)
    if IsPlayerSpell then local ok, k = pcall(IsPlayerSpell, id); if ok and k then return true end end
    if IsSpellKnown then local ok, k = pcall(IsSpellKnown, id); if ok and k then return true end end
    return false
end
local lineOfItem
function B.LineOf(id)
    if not lineOfItem then
        lineOfItem = {}
        for key, L in pairs(OMQ.BuyLines or {}) do
            for _, it in ipairs(L[2]) do lineOfItem[it[1]] = lineOfItem[it[1]] or key end
        end
    end
    return lineOfItem[id]
end
local function lineStock(line)
    local L = OMQ.BuyLines and OMQ.BuyLines[line]
    local n = 0
    for _, it in ipairs(L and L[2] or {}) do n = n + B.Have(it[1]) end
    return n
end
-- the lines left out for me: set of line keys
function B.Excluded(class, lines)
    local out = {}
    for _, b in ipairs(B.CLASS_BUFFS[class or ""] or {}) do
        local known = false
        for _, id in ipairs(b.spells) do if knowsSpell(id) then known = true; break end end
        if known then for _, l in ipairs(b.lines) do out[l] = true end end
    end
    for _, g in ipairs(B.EXCLUSIVE) do
        local stocked = {}
        for _, l in ipairs(g) do if not out[l] and lineStock(l) > 0 then stocked[l] = true end end   -- also one bought before
        if next(stocked) then
            for _, l in ipairs(g) do if not stocked[l] then out[l] = true end end
        end
    end
    return out
end

local function best(line, lvl)
    local L = OMQ.BuyLines and OMQ.BuyLines[line]
    if not L then return nil end
    local pick, prev
    for _, it in ipairs(L[2]) do
        local need = it[2]
        if L[1] == "spike" then need = math.max(it[2], it[3] - 5) end     -- spikes: by item level
        if need <= lvl then prev, pick = pick, it end
    end
    return pick and pick[1], L[1], prev and prev[1]
end

-- the weaker one of a line next to the best (decision 269): when filling up with the best costs more
-- than PRICEY of my gold and the weaker one costs at most CHEAPER of its price per piece
B.PRICEY, B.CHEAPER = 0.1, 1 / 3
function B.ShowCheaper(bestRow, alt)
    local b, a = bestRow.offers and bestRow.offers[1], alt.offers and alt.offers[1]
    if not (b and a and bestRow.state == "ok" and alt.state == "ok") then return false end
    local gold = GetMoney and GetMoney() or 0
    return b.unit * bestRow.target > gold * B.PRICEY and a.unit <= b.unit * B.CHEAPER
end

-- what kind of buff item this is: from the buy list, or a buff food the list does not know (decision 278).
-- A food (class 0, subclass 5) whose tooltip promises "Well Fed" counts as buff food - WoW Forever has
-- foods the Questie data does not list. The answer is kept for the session.
B.WELL_FED = 19705
B.WELL_FED_WORDS = { "well fed", "satt" }       -- English and German tooltip wording, besides the buff's own name
local foodSeen = {}
local function tipText(id)
    local T = C_TooltipInfo
    if not (T and T.GetItemByID) then return nil end
    local ok, data = pcall(T.GetItemByID, id)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local parts = {}
    for _, l in ipairs(data.lines) do
        local t = l.leftText
        if type(t) == "string" and not (issecretvalue and issecretvalue(t)) then parts[#parts + 1] = t end
    end
    return table.concat(parts, "\n"):lower()
end
function B.IsBuffFood(id)
    if foodSeen[id] ~= nil then return foodSeen[id] end
    local _, _, _, _, _, classID, subID = instant(id)
    if classID ~= 0 or subID ~= 5 then foodSeen[id] = false; return false end
    local text = tipText(id)
    if not text then return false end                       -- not known yet: ask again later
    local words = {}
    local wf = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(B.WELL_FED) or (GetSpellInfo and (GetSpellInfo(B.WELL_FED)))
    if type(wf) == "string" and wf ~= "" then words[#words + 1] = wf:lower() end
    for _, w in ipairs(B.WELL_FED_WORDS) do words[#words + 1] = w end
    local yes = false
    for _, w in ipairs(words) do
        if text:find(w, 1, true) then yes = true; break end
    end
    foodSeen[id] = yes
    return yes
end
function OMQ.BuyKind(id)
    if not id then return nil end
    local k = OMQ.BuyKnown and OMQ.BuyKnown[id]
    if k then return k end
    if B.IsBuffFood(id) then return "food" end
    return nil
end

-- remember buff items found in the bags
function B.LearnBags()
    local C = C_Container
    if not (C and C.GetContainerNumSlots) then return end
    local _, used = db()
    for bag = 0, OMQ.LastBag() do
        for slot = 1, C.GetContainerNumSlots(bag) or 0 do
            local it = C.GetContainerItemInfo(bag, slot)
            local kind = it and it.itemID and OMQ.BuyKind(it.itemID)
            if kind then used[it.itemID] = kind end
        end
    end
end

----------------------------------------------------------------------
-- The rows
----------------------------------------------------------------------
local rows, byId = {}, {}
local foods = {}           -- the buff foods for the cheapest-food row (decision 268)
local alts = {}            -- the weaker item of each line, priced to offer it when the best is dear (decision 269)
B._alts = alts
B._foods = foods
local weapons = {}
B._rows, B._weapons = rows, weapons

local function rowFor(id, kind, line, target, mine)
    local r = byId[id]
    if not r then
        local A = CA()
        r = { itemID = id, key = "b" .. id, state = "price", anyKey = true, onResult = nil,
              itemKey = (A and A.MakeItemKey and A.MakeItemKey(id)) or { itemID = id } }
        byId[id] = r
    end
    r.kind, r.line, r.target, r.mine, r.cheaper = kind, line, target, mine, nil
    return r
end

-- the fill-up target of an item on my buy list, nil when it is not on it (decision 274: selling keeps it)
function B.TargetFor(id)
    for _, r in ipairs(rows) do
        if r.itemID == id then return r.target end
    end
    return nil
end

-- buff foods in the bags or bought and on the way (decision 287): with one of them, no other buff food is offered
function B.HeldFoods()
    local held = {}
    local C = C_Container
    if C and C.GetContainerNumSlots then
        for bag = 0, OMQ.LastBag() do
            for slot = 1, C.GetContainerNumSlots(bag) or 0 do
                local it = C.GetContainerItemInfo(bag, slot)
                if it and it.itemID and OMQ.BuyKind(it.itemID) == "food" then held[it.itemID] = true end
            end
        end
    end
    for id in pairs(mailbox()) do
        if OMQ.BuyKind(id) == "food" and B.Have(id) > 0 then held[id] = true end
    end
    return held
end

-- the health potions from the best for my level down to the weakest (decision 288)
function B.HealChain(lvl)
    local L = OMQ.BuyLines and OMQ.BuyLines.heal
    local out = {}
    for _, it in ipairs(L and L[2] or {}) do
        if it[2] <= lvl then table.insert(out, 1, it[1]) end
    end
    return out
end
-- a potion is too dear when filling up with it costs more than PRICEY of my gold
function B.TooDear(r)
    local o = r.offers and r.offers[1]
    if not o then return true end
    return o.unit * r.target > (GetMoney and GetMoney() or 0) * B.PRICEY
end

-- an item found in the bags (B.LearnBags) comes back as a row only when it fits me (decision 402): an item of a
-- buy line only when the line is mine (no mana potions for a warrior, no intellect scroll for a rogue) and it is
-- not weaker than the best of its line for my level; buff food and items of no line as before
function B.UsedFits(id, kind, ln, myLines, lvl)
    if kind == "food" or not ln then return true end
    if not myLines[ln] then return false end
    local bestId = best(ln, lvl)
    if not bestId or bestId == id then return true end
    local L = OMQ.BuyLines[ln][2]
    local iBest, iMe
    for i, it in ipairs(L) do
        if it[1] == bestId then iBest = i end
        if it[1] == id then iMe = i end
    end
    return not (iBest and iMe and iMe < iBest)
end

function B.Build()
    for i = #rows, 1, -1 do rows[i] = nil end
    for i = #alts, 1, -1 do alts[i] = nil end
    local A = CA()
    local SC = OMQ.Score
    local class = SC and SC.MyClass() or select(2, UnitClass("player"))
    local role = SC and SC.MyRole() or "damage"
    local lvl = level()
    local never = (db())
    never = never.never
    local seen = {}
    local heldFood = B.HeldFoods()
    local anyFood = next(heldFood) ~= nil
    local function add(r)
        if r.kind == "food" and anyFood and not heldFood[r.itemID] then return end      -- one buff food is enough
        if not seen[r.itemID] and not never[r.itemID] then seen[r.itemID] = true; rows[#rows + 1] = r; r.order = #rows end
    end
    local lines = B.Lines(class, role)
    local excluded = B.Excluded(class, lines)
    local myLines = {}
    for _, l in ipairs(lines) do
        if l == "stone" then l = B.StoneLine() end
        if l then myLines[l] = true end
    end
    for _, line in ipairs(lines) do
        if line == "stone" then line = B.StoneLine() end
        if line == "heal" and not excluded[line] then
            -- always a health potion: the best one, or the next weaker one while it is too dear (decision 288)
            local target = B.TARGET.potion or 5
            local chain = B.HealChain(lvl)
            local shown, last, waiting
            for i, id in ipairs(chain) do
                local r = rowFor(id, "potion", "heal", target, false)
                if i > 1 then r.cheaper = true end
                alts[#alts + 1] = r
                if r.state == "ok" then
                    last = r
                    if not B.TooDear(r) then shown = r; break end
                elseif r.state ~= "none" then waiting = r; break end     -- not priced yet: ask it first
            end
            if not shown then
                shown = last or waiting or byId[chain[1] or 0]
            end
            if shown then add(shown) end
        elseif line and not excluded[line] then
            local id, kind, prevId = best(line, lvl)
            if id then
                local target = B.TARGET[kind] or 5
                if kind == "kit" then target = B.KitSlots() end
                if kind == "spike" then target = B.ShieldWithoutSpike() and 1 or 0 end
                if target > 0 then
                    local r = rowFor(id, kind, line, target, false)
                    add(r)
                    if prevId then
                        local alt = rowFor(prevId, kind, line, target, false)
                        alt.cheaper = true
                        alts[#alts + 1] = alt
                        if B.ShowCheaper(r, alt) then add(alt) end
                    end
                end
            end
        end
    end
    -- the cheapest buff food on sale: on WoW Forever every one gives +5% XP from kills (decision 268)
    for _, f in ipairs(foods) do f.xp = nil end
    local xp = B.CheapestFood(lvl)
    if xp then
        local r = rowFor(xp.itemID, "food", "xp", B.TARGET.food or 10, false)
        r.xp = true
        add(r)
    end
    -- what the dad bought himself before
    local _, used = db()
    for id, kind in pairs(used) do
        local minLevel = select(5, info(id))
        local ln = B.LineOf(id)
        if not seen[id] and (not minLevel or minLevel <= lvl) and kind ~= "kit" and kind ~= "spike"
            and ln ~= "heal" and not (ln and excluded[ln]) and B.UsedFits(id, kind, ln, myLines, lvl) then      -- health potions: see the chain above (decision 288)
            add(rowFor(id, kind, nil, B.TARGET[kind] or 5, true))
        end
    end
    for _, r in ipairs(rows) do
        r.have = B.Have(r.itemID)
        r.need = math.max(0, r.target - r.have)
        if A and A.MakeItemKey and not r.itemKey then r.itemKey = A.MakeItemKey(r.itemID) end
        r.itemKey = r.itemKey or { itemID = r.itemID }
    end
    table.sort(rows, function(a, b)
        local ka, kb = B.KIND_ORDER[a.kind] or 99, B.KIND_ORDER[b.kind] or 99
        if ka ~= kb then return ka < kb end
        if a.mine ~= b.mine then return not a.mine end
        return (a.order or 0) < (b.order or 0)
    end)
    return rows
end

-- the offers of a search: commodities by unit price, single auctions by buyout
local function readOffers(r)
    local A = CA()
    local offers = {}
    local nc = A.GetNumCommoditySearchResults and A.GetNumCommoditySearchResults(r.itemID) or 0
    if r.commodity ~= false and nc > 0 then
        r.commodity = true
        for i = 1, nc do
            local x = A.GetCommoditySearchResultInfo(r.itemID, i)
            if x and x.unitPrice and x.quantity then offers[#offers + 1] = { unit = x.unitPrice, qty = x.quantity } end
        end
    else
        local ni = A.GetNumItemSearchResults and A.GetNumItemSearchResults(r.itemKey) or 0
        if ni > 0 then r.commodity = false end
        for i = 1, ni do
            local x = A.GetItemSearchResultInfo(r.itemKey, i)
            if x and x.buyoutAmount and x.buyoutAmount > 0 then
                offers[#offers + 1] = { auctionID = x.auctionID, buyout = x.buyoutAmount, qty = x.quantity or 1,
                                        unit = math.floor(x.buyoutAmount / math.max(1, x.quantity or 1)), link = x.itemLink }
            end
        end
        table.sort(offers, function(a, b) return a.unit < b.unit end)
    end
    return offers
end

local function onStock(r)
    r.offers = readOffers(r)
    r.checkedAt = now()
    r.state = #r.offers > 0 and "ok" or "none"
    B.Build()                                   -- the cheapest food may have changed (decision 268)
end

-- what n pieces cost, and how many are there
function B.Cost(r, n)
    local total, got = 0, 0
    for _, o in ipairs(r.offers or {}) do
        if got >= n then break end
        local take = r.commodity and math.min(o.qty, n - got) or o.qty
        total = total + (r.commodity and o.unit * take or o.buyout)
        got = got + take
    end
    return total, got
end

----------------------------------------------------------------------
-- Weapon upgrades: a browse for weapons up to my level + 2, then the best few looked at closely
----------------------------------------------------------------------
-- what is scanned only on request (decision 290): the weapon browse and the bag browse
B.want = { weapons = false, bags = false }
local browse = { state = "idle" }
local candidates = {}
B._browse, B._candidates = browse, candidates

local function gainOf(link, equipLoc)
    local LP = OMQ.LootPreview
    if not (LP and LP.Gain) then return nil end
    local ok, g = pcall(LP.Gain, link, equipLoc)
    return ok and g or nil
end
local function budget() return math.floor((GetMoney and GetMoney() or 0) * B.WEAPON_GOLD_SHARE) end

-- cloth casters also look at wands (decision 298): a browse of its own, so the cheap weapons of the first
-- browse do not crowd them out; the best WANDS_CHECK wands are always looked at closely
B.WAND_CLASSES = { PRIEST = true, MAGE = true, WARLOCK = true }
B.WAND_SUBCLASS, B.WANDS_CHECK = 19, 2
function B.WantsWands(class)
    local SC = OMQ.Score
    class = class or (SC and SC.MyClass())
    return B.WAND_CLASSES[class or ""] and true or false
end

local function onBrowse(dump)
    local A = CA()
    local list = dump or (A.GetBrowseResults and A.GetBrowseResults() or {})
    browse.results = browse.results or {}
    for _, res in ipairs(list) do browse.results[#browse.results + 1] = res end
    if not dump and browse.state == "asking" and B.WantsWands() then browse.state = "wands"; return end   -- the wand browse next
    browse.state = "done"
    list = browse.results
    browse.results = nil
    for i = #candidates, 1, -1 do candidates[i] = nil end
    local SC = OMQ.Score
    local class = SC and SC.MyClass()
    local lvl = level()
    local scored, seen = {}, {}
    for _, res in ipairs(list) do
        local id = res.itemKey and res.itemKey.itemID
        local _, _, _, equipLoc, _, classID = instant(id or 0)
        local minLevel = select(5, info(id or 0))
        if id and classID == 2 and (res.minPrice or 0) <= budget() and (not minLevel or minLevel <= lvl + B.WEAPON_LEVELS)
            and (not SC or SC.CanUse("item:" .. id, class, lvl + B.WEAPON_LEVELS)) then
            local g = gainOf("item:" .. id, equipLoc) or 0
            local k = AH()._KeyString(res.itemKey)
            if not seen[k] then
                seen[k] = true
                scored[#scored + 1] = { itemKey = res.itemKey, itemID = id, equipLoc = equipLoc, est = g,
                                        wand = select(7, instant(id)) == B.WAND_SUBCLASS }
            end
        end
    end
    table.sort(scored, function(a, b) return a.est > b.est end)
    local pick, wands = {}, 0
    for i = 1, math.min(B.WEAPON_CHECK, #scored) do pick[#pick + 1] = scored[i]; if scored[i].wand then wands = wands + 1 end end
    for i = B.WEAPON_CHECK + 1, #scored do
        if wands >= B.WANDS_CHECK then break end
        if scored[i].wand and scored[i].est > 0 then pick[#pick + 1] = scored[i]; wands = wands + 1 end
    end
    for _, c in ipairs(pick) do
        c.key, c.state, c.commodity = "w" .. AH()._KeyString(c.itemKey), "price", false
        c.anyKey = dump and true or nil                       -- the key of the dump is a guess: the game's own key is taken from its answer (decision 343)
        c.onResult = function(x)
            x.state = "done"
            local bestO, bestG
            for _, o in ipairs(readOffers(x)) do
                local need = select(5, info(o.link or 0))
                if o.link and o.buyout <= budget() and not (need and need > level() + B.WEAPON_LEVELS) then
                    local g = gainOf(o.link, x.equipLoc)
                    if g and g > 0 and (not bestG or g > bestG or (g == bestG and o.buyout < bestO.buyout)) then bestO, bestG = o, g end
                end
            end
            x.offer, x.gain = bestO, bestG
        end
        candidates[#candidates + 1] = c
    end
end

-- the level a weapon offer needs; nil while the game has not loaded the item (it is asked for)
local function needLevel(link)
    local need = select(5, info(link))
    if need == nil and C_Item and C_Item.RequestLoadItemDataByID then
        local id = tonumber(tostring(link):match("item:(%d+)"))
        if id then pcall(C_Item.RequestLoadItemDataByID, id) end
    end
    return need
end
B.NeedLevel = needLevel
function B.Weapons()
    for i = #weapons, 1, -1 do weapons[i] = nil end
    local never = (db()).never
    local maxLevel = level() + B.WEAPON_LEVELS
    for _, c in ipairs(candidates) do
        -- only what I can wield within WEAPON_LEVELS: an offer whose level is not known yet waits (decision 402)
        local need = c.offer and needLevel(c.offer.link)
        if c.offer and c.gain and need and need <= maxLevel and not never[c.itemID] and not c.bought then weapons[#weapons + 1] = c end
    end
    table.sort(weapons, function(a, b) return a.gain > b.gain end)
    for i = #weapons, B.WEAPON_ROWS + 1, -1 do weapons[i] = nil end
    return weapons
end

----------------------------------------------------------------------
-- Bags (decision 265): a bigger bag for the smallest one (or an empty bag slot), the bag of a
-- profession I have (herbs, enchanting, engineering), a soul bag for warlocks, a quiver or ammo pouch
-- for hunters - each only when none of that kind is worn or a bigger one is on sale, at most half
-- my gold. Slots come from the item's tooltip ("16 Slot Bag"), in the client's language.
----------------------------------------------------------------------
local bagBrowse = { state = "idle" }
local bagCands = {}
B._bagBrowse, B._bagCands = bagBrowse, bagCands
B.BAG_ROWS = 6
B.BAG_LABEL = { ["1/0"] = "bag", ["1/1"] = "soul bag", ["1/2"] = "herb bag", ["1/3"] = "enchanting bag", ["1/4"] = "engineering bag",
                ["11/2"] = "quiver", ["11/3"] = "ammo pouch" }
B.PROF_BAG = { [182] = 2, [333] = 3, [202] = 4 }       -- skill line -> bag subclass (herbs, enchanting, engineering)

-- The reagent bag (decision 330; "Handwerkstaschen" in the German client): the general bag for every crafting
-- reagent, worn in its own slot (Enum.BagIndex.ReagentBag). It is a container subclass of its own; which number
-- it has the game tells: the subclass names of the containers (the auction house's category list) are read and
-- the one that names reagents or crafting is the reagent bag. Failing that, the reagent bag I wear tells it.
B.REAGENT_WORDS = { "reagent", "reagenz", "crafting", "handwerk" }
local reagentKey
function B.ResetReagentKey() reagentKey = nil end
local function subClassName(c, sub)
    local f = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
    if not f then return nil end
    local ok, n = pcall(f, c, sub)
    if ok and type(n) == "string" and n ~= "" and not isSecret(n) then return n end
end
-- the container categories of the game: { { sub = 0, name = "Bag" }, ... }
function B.ContainerSubclasses()
    local out = {}
    for sub = 0, 20 do
        local n = subClassName(1, sub)
        if n then out[#out + 1] = { sub = sub, name = n } end
    end
    return out
end
function B.ReagentKey()
    if reagentKey then return reagentKey end
    local E = Enum and Enum.ItemContainerSubclass
    if E and type(E.Reagent) == "number" then reagentKey = "1/" .. E.Reagent; return reagentKey end
    for _, c in ipairs(B.ContainerSubclasses()) do
        local l = c.name:lower()
        for _, w in ipairs(B.REAGENT_WORDS) do
            if l:find(w, 1, true) then reagentKey = "1/" .. c.sub; return reagentKey end
        end
    end
    local R = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    local C = C_Container
    local inv = type(R) == "number" and C and C.ContainerIDToInventoryID and C.ContainerIDToInventoryID(R)
    local id = inv and GetInventoryItemID and GetInventoryItemID("player", inv)
    if id then
        local _, _, _, _, _, classID, sub = instant(id)
        if classID == 1 and (sub or 0) > 4 then reagentKey = "1/" .. sub; return reagentKey end
    end
    return nil
end
function B.KindLabel(k)
    if k and k == B.ReagentKey() then return "reagent bag" end
    return B.BAG_LABEL[k]
end

-- The tooltip line with the slot count, from the game's own format CONTAINER_SLOTS (decision 327). The
-- format may use positional arguments ("%2$s ... %1$d", common in German); they are turned into plain
-- placeholders first, then everything else is escaped. A format that still can not be used falls back to
-- "a number at the start of the line".
function B.SlotPattern(f)
    f = f or CONTAINER_SLOTS or "%d Slot %s"
    local p = f:gsub("%%%d+%$d", "\001"):gsub("%%d", "\001"):gsub("%%%d+%$s", "\002"):gsub("%%s", "\002")
    p = p:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = "^" .. p:gsub("\001", "(%%d+)"):gsub("\002", ".+") .. "$"
    if not pcall(string.match, "", p) then p = "^(%d+)%s" end
    return p
end
local slotPattern
function B.ResetSlotPattern() slotPattern = nil end
function B.BagSlots(id)
    if not slotPattern then slotPattern = B.SlotPattern() end
    local T = C_TooltipInfo
    if not (T and T.GetItemByID) then return nil end
    local ok, data = pcall(T.GetItemByID, id)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    for _, l in ipairs(data.lines) do
        local t = l.leftText
        if type(t) == "string" and not isSecret(t) then
            local ok2, m = pcall(string.match, t, slotPattern)
            local n = ok2 and tonumber(m or "")
            if n then return n end
        end
    end
    return nil
end

-- what I wear in the four bag slots: { normal = smallest slots (0 = an empty slot), kinds = { [classID.."/"..sub] = slots } }
function B.WornBags()
    local C = C_Container
    local smallest, kinds = nil, {}
    for bag = 1, (NUM_BAG_SLOTS or 4) do
        local inv = C and C.ContainerIDToInventoryID and C.ContainerIDToInventoryID(bag)
        local id = inv and GetInventoryItemID and GetInventoryItemID("player", inv)
        local n = C and C.GetContainerNumSlots and C.GetContainerNumSlots(bag) or 0
        if not id or n == 0 then smallest = 0
        else
            local _, _, _, _, _, classID, sub = instant(id)
            if classID == 1 and (sub or 0) == 0 then
                if not smallest or n < smallest then smallest = n end
            else
                local k = (classID or 0) .. "/" .. (sub or 0)
                kinds[k] = math.max(kinds[k] or 0, n)
            end
        end
    end
    -- the reagent bag sits in its own slot (decision 330); no bag there = 0 slots
    local R, rk = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag, B.ReagentKey()
    if rk and type(R) == "number" then
        local n = C and C.GetContainerNumSlots and C.GetContainerNumSlots(R) or 0
        kinds[rk] = math.max(kinds[rk] or 0, n)
    end
    return { normal = smallest, kinds = kinds }
end

-- which special bags I could use: "1/2" herbs, "1/3" enchanting, "1/4" engineering, "1/1" soul, "11/2" quiver, "11/3" ammo pouch
function B.WantedKinds()
    local want = {}
    if GetProfessions and GetProfessionInfo then
        for _, idx in ipairs({ GetProfessions() }) do
            if idx then
                local line = select(7, GetProfessionInfo(idx))
                if B.PROF_BAG[line] then want["1/" .. B.PROF_BAG[line]] = true end
            end
        end
    end
    local rk = B.ReagentKey()
    if rk then want[rk] = true end                         -- the reagent bag: for everybody, next to the profession bag
    local _, class = UnitClass("player")
    if class == "WARLOCK" then want["1/1"] = true end
    if class == "HUNTER" then
        local link = GetInventoryItemLink and GetInventoryItemLink("player", 18)
        local sub = link and select(7, instant(link))
        if sub == 3 then want["11/3"] = true else want["11/2"] = true end     -- a gun takes bullets
    end
    return want
end

-- The bag search (decision 325, like the weapon search): one browse for containers (class 1, the game's
-- "Containers" category), for hunters a second one for quivers and ammo pouches (class 11, like the wand
-- browse of the weapons). Each answer is read at once, there is no paging. Then every result is judged:
-- one row per bag type with the cheapest offer. The slot count comes from the item's tooltip; the game
-- knows it only once the item is loaded, so unread bags are loaded and judged again (at most B.BAG_TRIES).
B.BAG_TRIES, B.BAG_RETRY = 3, 1.5

local function judgeBags()
    for i = #bagCands, 1, -1 do bagCands[i] = nil end
    local worn, want = B.WornBags(), B.WantedKinds()
    local bestOf, unread = {}, {}
    local st = { results = 0, bags = 0, unread = 0, tooDear = 0, notBetter = 0, kinds = {} }
    for _, res in ipairs(bagBrowse.results or {}) do
        st.results = st.results + 1
        local okR, errR = pcall(function()
        local id = res.itemKey and res.itemKey.itemID
        local _, _, _, _, _, classID, sub = instant(id or 0)
        if classID == 1 or classID == 11 then
            st.bags = st.bags + 1
            local kk = (classID or 0) .. "/" .. (sub or 0)
            st.kinds[kk] = (st.kinds[kk] or 0) + 1
            local slots = id and B.BagSlots(id)
            if not slots then
                st.unread = st.unread + 1; unread[#unread + 1] = id
            elseif (res.minPrice or 0) > budget() then
                st.tooDear = st.tooDear + 1
            else
                local k = (classID or 0) .. "/" .. (sub or 0)
                local ok
                if k == "1/0" then ok = worn.normal ~= nil and slots > worn.normal
                else ok = want[k] and slots > (worn.kinds[k] or 0) end
                if not ok then st.notBetter = st.notBetter + 1 end
                -- one row per bag type (decision 322): the kind and the slots, e.g. "herb bag 12"; the cheapest of it
                local t = k .. ":" .. slots
                local cur = bestOf[t]
                if ok and (not cur or (res.minPrice or 0) < cur.price) then
                    bestOf[t] = { itemKey = res.itemKey, itemID = id, slots = slots, price = res.minPrice or 0, bagKind = k }
                end
            end
        end
        end)
        if not okR then st.errors = (st.errors or 0) + 1; st.err = st.err or tostring(errR) end
    end
    bagBrowse.stats = st
    for t, c in pairs(bestOf) do
        local k = c.bagKind
        c.key, c.state, c.anyKey = "g" .. t, "price", true
        c.onResult = function(x) x.offers = readOffers(x); x.checkedAt = now(); x.state = #x.offers > 0 and "ok" or "none" end
        c.replaces = (k == "1/0") and worn.normal or (worn.kinds[k] or 0)
        bagCands[#bagCands + 1] = c
    end
    -- normal bags first, then the reagent bags, then the other special kinds; within a kind the biggest first
    local rk = B.ReagentKey()
    local function rank(k) return (k == "1/0" and 0) or (k == rk and 1) or 2 end
    table.sort(bagCands, function(a, b)
        local ra, rb = rank(a.bagKind), rank(b.bagKind)
        if ra ~= rb then return ra < rb end
        if a.bagKind ~= b.bagKind then return a.bagKind < b.bagKind end
        return a.slots > b.slots
    end)
    return unread
end

function B.JudgeBags()
    local okJ, unread = pcall(judgeBags)
    if not okJ then
        bagBrowse.stats = bagBrowse.stats or {}
        bagBrowse.stats.err = tostring(unread)
        bagBrowse.state = "done"
        return
    end
    if #unread > 0 and (bagBrowse.tries or 0) < B.BAG_TRIES then
        -- not loaded yet: ask the game for the items and look again a moment later
        for i = #bagCands, 1, -1 do bagCands[i] = nil end
        bagBrowse.state = "loading"
        bagBrowse.tries = (bagBrowse.tries or 0) + 1
        local I = C_Item
        for _, id in ipairs(unread) do
            if I and I.RequestLoadItemDataByID then pcall(I.RequestLoadItemDataByID, id) end
        end
        local again = function()
            if bagBrowse.state ~= "loading" then return end
            B.JudgeBags()
            local H = AH(); if H then H.Refresh(); H.Pump() end
        end
        if C_Timer and C_Timer.After then C_Timer.After(B.BAG_RETRY, again) else again() end
        return
    end
    bagBrowse.state = "done"
end

local function wantsQuivers()
    local _, class = UnitClass("player")
    return class == "HUNTER"
end

-- the answer of a bag browse: read it at once, like the weapons (decision 325)
local function onBagBrowse(q)
    local A = CA()
    bagBrowse.answered = (bagBrowse.answered or 0) + (q and q.answered and 1 or 0)
    bagBrowse.results = bagBrowse.results or {}
    local got = A.GetBrowseResults and A.GetBrowseResults() or {}
    for _, res in ipairs(got) do bagBrowse.results[#bagBrowse.results + 1] = res end
    -- what each browse saw (decision 326): the game's answers and how many results were read
    bagBrowse.log = bagBrowse.log or {}
    bagBrowse.log[#bagBrowse.log + 1] = string.format("%s: %s, read %d", tostring(q and q.key), (q and q.answers) and table.concat(q.answers, "; ") or "no answer (timeout)", #got)
    if bagBrowse.state == "asking" and wantsQuivers() then bagBrowse.state = "quivers"; return end   -- the quiver browse next
    bagBrowse.tries = 0
    B.JudgeBags()
end

-- /omq ah bags: what the bag search saw (decisions 320, 325)
function B.BagReport()
    local worn, want = B.WornBags(), B.WantedKinds()
    local kinds, wk = {}, {}
    for k, n in pairs(worn.kinds) do kinds[#kinds + 1] = (B.KindLabel(k) or k) .. " " .. n end
    for k in pairs(want) do wk[#wk + 1] = B.KindLabel(k) or k end
    local st = bagBrowse.stats or {}
    local H = AH()
    local q, age = nil, 0
    if H and H._Asking then q, age = H._Asking() end
    local lines = {
        string.format("v%s bags: scan %s, state %s, answers of the game %d", tostring(OMQ.version),
            B.want.bags and "requested" or "not requested", tostring(bagBrowse.state), bagBrowse.answered or 0),
        "worn: smallest normal bag " .. tostring(worn.normal) .. (#kinds > 0 and (", " .. table.concat(kinds, ", ")) or ""),
        "special bags for you: " .. (#wk > 0 and table.concat(wk, ", ") or "none") .. ", budget " .. money0(budget()),
        string.format("results %d, bags %d, slots unread %d (tries %d), too dear %d, not bigger %d",
            st.results or 0, st.bags or 0, st.unread or 0, bagBrowse.tries or 0, st.tooDear or 0, st.notBetter or 0),
        "the queue waits for: " .. (q and (tostring(q.key) .. " since " .. math.floor(age) .. "s") or "nothing"),
        "slot line format: " .. tostring(CONTAINER_SLOTS) .. " -> " .. B.SlotPattern(),
    }
    -- the container categories of the game and which one is the reagent bag (decision 330)
    local cats = {}
    for _, c in ipairs(B.ContainerSubclasses()) do cats[#cats + 1] = c.sub .. " " .. c.name end
    lines[#lines + 1] = "container categories: " .. (#cats > 0 and table.concat(cats, ", ") or "not readable") ..
        "; reagent bag kind: " .. tostring(B.ReagentKey())
    local seen = {}
    for k, n in pairs(st.kinds or {}) do seen[#seen + 1] = k .. " x" .. n end
    table.sort(seen)
    lines[#lines + 1] = "kinds seen in the answers: " .. (#seen > 0 and table.concat(seen, ", ") or "none")
    if st.err then lines[#lines + 1] = string.format("ERROR (%d): %s", st.errors or 1, st.err) end
    for _, l in ipairs(bagBrowse.log or {}) do lines[#lines + 1] = "  " .. l end
    for _, c in ipairs(bagCands) do
        lines[#lines + 1] = string.format("  %s: item %d, %d slots, %s (%s)", B.KindLabel(c.bagKind) or c.bagKind, c.itemID, c.slots, money0(c.price or 0), tostring(c.state))
    end
    return lines
end

function B.Bags()
    local out = {}
    local never = (db()).never
    for _, c in ipairs(bagCands) do
        if c.state == "ok" and not never[c.itemID] and not c.bought then out[#out + 1] = c end
    end
    B.bagsMore = math.max(0, #out - B.BAG_ROWS)
    -- every bag type gets its first (biggest) row before one type fills them all: the reagent bag is always shown
    -- next to the profession bag (decision 330); the rest of the rows go by the usual order
    local keep, seenKind, nKeep = {}, {}, 0
    for _, c in ipairs(out) do
        if not seenKind[c.bagKind] and nKeep < B.BAG_ROWS then seenKind[c.bagKind] = true; keep[c] = true; nKeep = nKeep + 1 end
    end
    for _, c in ipairs(out) do
        if not keep[c] and nKeep < B.BAG_ROWS then keep[c] = true; nKeep = nKeep + 1 end
    end
    local shown = {}
    for _, c in ipairs(out) do if keep[c] then shown[#shown + 1] = c end end
    return shown
end

-- buff foods I can eat: their prices are looked at once, the cheapest per piece becomes a row
function B.FoodCandidates(lvl)
    for i = #foods, 1, -1 do foods[i] = nil end
    for _, f in ipairs(OMQ.BuyFoods or {}) do
        if f[2] <= lvl then
            local r = rowFor(f[1], "food", nil, B.TARGET.food or 10, false)
            foods[#foods + 1] = r
        end
    end
    return foods
end
function B.CheapestFood(lvl)
    local best
    for _, r in ipairs(foods) do
        local o = r.offers and r.offers[1]
        if r.state == "ok" and o and (not best or o.unit < best.offers[1].unit) then best = r end
    end
    return best
end

-- is a search of the buy mode still to come? (decision 286)
function B.Pending()
    for _, list in ipairs({ rows, foods, alts, candidates, bagCands }) do
        for _, r in ipairs(list) do if r.state == "price" then return true end end
    end
    return (B.want.weapons and browse.state ~= "done") or (B.want.bags and bagBrowse.state ~= "done") and true or false
end
-- the weapon scan, on request (decision 290)
function B.ScanWeapons()
    B.want.weapons = true
    browse.state = "idle"
    for i = #candidates, 1, -1 do candidates[i] = nil end
    AH().Refresh(); AH().Pump()
end
-- the bag scan, on request (decision 320, like the weapons)
local function resetBags()
    bagBrowse.state, bagBrowse.tries, bagBrowse.results, bagBrowse.stats, bagBrowse.answered, bagBrowse.log = "idle", 0, nil, nil, 0, nil
    for i = #bagCands, 1, -1 do bagCands[i] = nil end
end
function B.ScanBags()
    B.want.bags = true
    resetBags()
    AH().Refresh(); AH().Pump()
end
-- everything again: the stock prices, the weapons, the bags (decision 290)
function B.ScanAll()
    B.want.weapons, B.want.bags = true, true
    browse.state = "idle"
    resetBags()
    for i = #candidates, 1, -1 do candidates[i] = nil end
    for i = #bagCands, 1, -1 do bagCands[i] = nil end
    for _, r in pairs(byId) do r.state = "price" end
    B.Build()
end

-- the dump of the whole house answers what it can (decision 343): the stock prices of stackable items, and the
-- weapons and bags, which are judged at once; only the offers of the few candidates are searched later
local function dumpList(classes)
    local P, out = OMQ.Prices, {}
    local make = C_AuctionHouse and C_AuctionHouse.MakeItemKey
    for id, e in pairs(P.Items()) do
        local classID = select(6, instant(id))
        if classes[classID] then
            out[#out + 1] = { itemKey = make and make(id) or { itemID = id, itemLevel = 0, itemSuffix = 0 }, minPrice = e.p, totalQuantity = e.q }
        end
    end
    return out
end
function B.UseDump()
    local P = OMQ.Prices
    if not (P and P.Session and P.Session()) then return end
    local changed = false
    for _, list in ipairs({ rows, foods, alts }) do
        for _, r in ipairs(list) do
            if r.state == "price" and not r.live then
                local stack = select(8, info(r.itemID))
                if (stack or 1) > 1 then
                    local p, q = P.Auction(r.itemID)
                    B.FromBatch(r, p and { minPrice = p, totalQuantity = q } or nil)
                    changed = true
                end
            end
        end
    end
    if browse.state == "idle" then
        B.want.weapons = true
        browse.results, browse.state = nil, "done"
        local ok, err = pcall(onBrowse, dumpList({ [2] = true }))
        if not ok then OMQ:Error("auction buy dump", err) end
    end
    if bagBrowse.state == "idle" then
        B.want.bags = true
        bagBrowse.results, bagBrowse.tries, bagBrowse.answered = dumpList({ [1] = true, [11] = true }), 0, 0
        bagBrowse.log = { "from the dump of the whole house" }
        B.JudgeBags()
    end
    if changed then B.Build() end
end

-- the next search the auction helper's queue should send (after its own price checks)
function B.NextQuery()
    for _, r in ipairs(rows) do
        if r.state == "price" then r.onResult = onStock; return r end
    end
    for _, r in ipairs(foods) do
        if r.state == "price" then r.onResult = onStock; return r end
    end
    for _, r in ipairs(alts) do
        if r.state == "price" then r.onResult = onStock; return r end
    end
    if B.want.weapons and browse.state == "wands" then
        local P = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
        local lvl = level()
        browse.state = "asking wands"
        return { browse = true, key = "wands", onResult = function() onBrowse() end,
                 query = { searchString = "", sorts = { { sortOrder = P, reverseSort = false } },
                           minLevel = math.max(1, lvl - 8), maxLevel = lvl + B.WEAPON_LEVELS,
                           itemClassFilters = { { classID = 2, subClassID = B.WAND_SUBCLASS } } } }
    end
    if B.want.weapons and browse.state == "idle" then
        local P = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
        local lvl = level()
        browse.results = nil
        browse.state = "asking"
        return { browse = true, key = "browse", onResult = function() onBrowse() end,
                 query = { searchString = "", sorts = { { sortOrder = P, reverseSort = false } },
                           minLevel = math.max(1, lvl - 8), maxLevel = lvl + B.WEAPON_LEVELS,
                           itemClassFilters = { { classID = 2 } } } }
    end
    for _, c in ipairs(candidates) do
        if c.state == "price" then return c end
    end
    if B.want.bags and (bagBrowse.state == "idle" or bagBrowse.state == "quivers") then
        local P = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
        local class = bagBrowse.state == "quivers" and 11 or 1
        bagBrowse.state = class == 1 and "asking" or "asking quivers"
        return { browse = true, key = "bags" .. class, onResult = function(q) onBagBrowse(q) end,
                 query = { searchString = "", sorts = { { sortOrder = P, reverseSort = false } },
                           itemClassFilters = { { classID = class } } } }
    end
    for _, c in ipairs(bagCands) do
        if c.state == "price" then return c end
    end
    return nil
end

----------------------------------------------------------------------
-- Buying (from a click)
----------------------------------------------------------------------
local buying = nil
B._buying = function() return buying end
-- fast clicks (decision 281): one purchase at a time. A click while one is on its way is ignored; a
-- purchase the game never answers is given up after B.BUY_WAIT seconds, so nothing hangs.
B.BUY_WAIT = 6
local done
local late = nil           -- the purchase given up last: a confirmation that comes late still counts (decision 402)
B.LATE_WAIT = 30
function B.Busy()
    if not buying then return false end
    if now() - (buying.at or 0) < B.BUY_WAIT then return true end
    local b = buying
    done(false, "no answer from the auction house - click again")
    late = { b = b, at = now() }
    return false
end
local function succeeded()
    if not buying and late and now() - late.at < B.LATE_WAIT then buying = late.b end
    late = nil
    done(true)
end
local function watch()
    if C_Timer and C_Timer.After then C_Timer.After(B.BUY_WAIT + 0.1, function() B.Busy() end) end
end

local function afford(cost)
    if (GetMoney and GetMoney() or 0) < cost then
        OMQ:Print("auction helper: not enough gold (" .. money(cost) .. ")")
        return false
    end
    return true
end

function B.Buy(r, n)
    local A = CA()
    if not (A and r and r.offers and #r.offers > 0) or B.Busy() or not AH().open then return false end
    AH().Quiet()                                                       -- clicks go first (decision 293)
    if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then AH().WaitNote(); return false end   -- a search is on its way
    n = math.max(1, n or 1)
    if r.commodity then
        local cost, got = B.Cost(r, n)
        n = math.min(n, got)
        if n < 1 or not afford(cost) then return false end
        buying = { row = r, qty = n, base = B.Have(r.itemID), at = now(), expect = cost }
        A.StartCommoditiesPurchase(r.itemID, n)
    else
        local o = r.offers[1]
        if not afford(o.buyout) then return false end
        buying = { row = r, qty = o.qty, auctionID = o.auctionID, base = B.Have(r.itemID), at = now() }
        table.remove(r.offers, 1)
        A.PlaceBid(o.auctionID, o.buyout)
    end
    watch()
    AH().Refresh()
    return true
end

function B.BuyWeapon(w)
    local A = CA()
    if not (A and w and w.offer) or B.Busy() or not AH().open then return false end
    AH().Quiet()
    if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then AH().WaitNote(); return false end
    if not afford(w.offer.buyout) then return false end
    buying = { weapon = w, auctionID = w.offer.auctionID, at = now() }
    A.PlaceBid(w.offer.auctionID, w.offer.buyout)
    watch()
    AH().Refresh()
    return true
end

-- a click on a stock row: fill up (what is missing) or a single piece
function B.Click(r)
    if not r then return false end
    if B.Mode() == "single" then return B.Buy(r, 1) end
    return B.Buy(r, math.max(1, r.need or 1))
end

-- "Fill everything up": the next row that misses something
function B.FillNext()
    for _, r in ipairs(rows) do
        if (r.need or 0) > 0 and r.offers and #r.offers > 0 then return B.Buy(r, r.need) end
    end
    return false
end

-- the consumables clicked away (right click: never suggest) - not the weapons and bags (decision 275)
local function isConsumable(id)
    if OMQ.BuyKind(id) then return true end
    local classID = select(6, instant(id))
    return classID ~= nil and classID ~= 1 and classID ~= 2 and classID ~= 11
end
function B.NeverCount()
    local n = 0
    for id in pairs(db().never) do if isConsumable(id) then n = n + 1 end end
    return n
end
function B.ResetNever()
    local never = db().never
    for id in pairs(never) do if isConsumable(id) then never[id] = nil end end
    for _, r in pairs(byId) do r.state = "price" end
    B.Build()
    AH().Refresh()
    AH().Pump()
end

function B.Never(id)
    db().never[id] = true
    B.Build()
    AH().Refresh()
end

function done(ok, why)
    local b = buying
    buying = nil
    if b and b.weapon then
        b.weapon.bought = ok or nil
        if not ok then b.weapon.state, b.weapon.offer, b.weapon.gain = "price", nil, nil end   -- gone or refused: look again (decision 402)
    end
    if b and b.row then
        if ok and not b.row.bagKind then B.Bought(b.row.itemID, b.qty, b.base); B.Consume(b.row, b.qty) end
        if b.row.bagKind then b.row.bought = ok or nil
        elseif not ok then b.row.state, b.row.live, b.row.estimate = "price", true, nil end    -- failed: a real search of the offers, no estimate (decision 402)
    end
    if not ok and why then OMQ:Print("auction helper: " .. why) end
    B.Build()
    AH().Ready()
    AH().Refresh()
    AH().Pump()
end
-- a purchase went through: what I bought is gone from the known offers, no new search (decision 293)
function B.Consume(r, n)
    if not (r and r.offers) then return end
    if r.commodity then
        local left = n or 0
        while left > 0 and r.offers[1] do
            local o = r.offers[1]
            local take = math.min(o.qty or 0, left)
            o.qty, left = (o.qty or 0) - take, left - take
            if o.qty <= 0 then table.remove(r.offers, 1) end
        end
    end
    if #r.offers == 0 then r.state = "none" end
end
-- the stock rows one batch request can price: stackable items, not asked yet (decision 293)
function B.BatchRows()
    local out, tried = {}, AH()._tried or {}
    for _, list in ipairs({ rows, foods, alts }) do
        for _, r in ipairs(list) do
            if r.state == "price" and not tried[r.key] and not r.listed and not r.live then
                local stack = select(8, info(r.itemID))
                if (stack or 1) > 1 then r.listed = true; out[#out + 1] = r end
            end
        end
    end
    for _, r in ipairs(out) do r.listed = nil end
    return out
end
-- the answer of a batch: the lowest price per piece and how many there are, an estimate until a click
function B.FromBatch(r, res)
    r.checkedAt = now()
    if res then
        r.offers = { { unit = res.minPrice, qty = res.totalQuantity or 1 } }
        r.commodity, r.estimate, r.state = true, true, "ok"
    else
        r.offers, r.state = {}, "none"
    end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
                     "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR",
                     "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "MAIL_INBOX_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
-- the game's price for a purchase may be above an estimate: then no purchase, the offers are looked at
-- closely and the next click buys at the real price (decision 293)
B.PRICE_SLACK = 1.2
function B.PriceOk(expect, total)
    if not (expect and total) then return true end
    return total <= expect * B.PRICE_SLACK + 100
end
ev:SetScript("OnEvent", function(_, event, a1, a2)
    local ok, err = pcall(function()
        if event == "MAIL_INBOX_UPDATE" then B.CheckMail(); return end
        if not (AH() and AH().open) then return end
        local A = CA()
        if event == "COMMODITY_PRICE_UPDATED" then
            if buying and buying.row then
                if B.PriceOk(buying.expect, a2) then
                    A.ConfirmCommoditiesPurchase(buying.row.itemID, buying.qty)
                else
                    if A.CancelCommoditiesPurchase then A.CancelCommoditiesPurchase() end
                    buying.row.estimate = nil
                    done(false, "the price is higher than shown (" .. money(a2) .. " in all) - looking again, click once more to buy")
                end
            end
        elseif event == "COMMODITY_PRICE_UNAVAILABLE" then done(false, "that price is gone - looking again")
        elseif event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then succeeded()
        elseif event == "COMMODITY_PURCHASE_FAILED" then done(false, "the purchase failed")
        elseif event == "AUCTION_HOUSE_SHOW_ERROR" then if buying then done(false, "the auction house refused it") end
        elseif event == "BAG_UPDATE_DELAYED" then B.LearnBags(); B.Build(); AH().Refresh()
        elseif event == "GET_ITEM_INFO_RECEIVED" then AH().Refresh() end
    end)
    if not ok then OMQ:Error("auction buy", err) end
end)

function B.Open()
    buying, late = nil, nil
    B.want.weapons, B.want.bags = false, false
    browse.state = "idle"
    resetBags()
    for i = #candidates, 1, -1 do candidates[i] = nil end
    for i = #bagCands, 1, -1 do bagCands[i] = nil end
    for _, r in pairs(byId) do r.state, r.live = "price", nil end
    B.LearnBags()
    B.FoodCandidates(level())
    B.Build()
end

----------------------------------------------------------------------
-- Drawing (inside the auction helper's panel)
----------------------------------------------------------------------
local ui
B._ui = function() return ui end
local function fs(parent, font, r, g, b)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    t:SetJustifyH("LEFT")
    if r then t:SetTextColor(r, g, b) end
    return t
end
local function qColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function makeRow(parent, h)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(348, h)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); r.bg:SetColorTexture(0.11, 0.122, 0.153, 1)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(h - 8, h - 8); r.icon:SetPoint("LEFT", 4, 0)
    r.name = fs(r, "GameFontHighlight"); r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -1); r.name:SetWidth(240)
    if r.name.SetWordWrap then r.name:SetWordWrap(false) end
    r.sub = fs(r, "GameFontDisableSmall"); r.sub:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 8, 1); r.sub:SetWidth(200)
    if r.sub.SetWordWrap then r.sub:SetWordWrap(false) end
    r.top = fs(r, "GameFontNormal"); r.top:SetPoint("TOPRIGHT", -6, -4); r.top:SetJustifyH("RIGHT")
    r.bottom = fs(r, "GameFontNormalSmall", 0.95, 0.82, 0.48); r.bottom:SetPoint("BOTTOMRIGHT", -6, 4); r.bottom:SetJustifyH("RIGHT")
    r:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return r
end

local function build(panel)
    ui = CreateFrame("Frame", nil, panel)
    if panel.box then ui:SetFrameLevel(panel.box:GetFrameLevel() + 2) end
    ui.head = fs(ui, "GameFontHighlight", 0.79, 0.8, 0.84); ui.head:SetPoint("TOPLEFT", 16, -2); ui.head:SetWidth(348)
    ui.wTitle = fs(ui, "GameFontNormal", 0.95, 0.82, 0.48); ui.wTitle:SetText("Weapon upgrades")
    ui.sTitle = fs(ui, "GameFontNormal", 0.95, 0.82, 0.48); ui.sTitle:SetText("Stock up")
    ui.wRows, ui.sRows = {}, {}
    for i = 1, B.WEAPON_ROWS do
        local r = makeRow(ui, 42)
        r:SetScript("OnClick", function(self, button)
            if not self.w then return end
            if button == "RightButton" then B.Never(self.w.itemID) else B.BuyWeapon(self.w) end
        end)
        r:SetScript("OnEnter", function(self)
            if GameTooltip and self.w and self.w.offer and self.w.offer.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.w.offer.link); GameTooltip:Show()
            end
        end)
        ui.wRows[i] = r
    end
    ui.offset = 0
    ui:EnableMouseWheel(true)
    ui:SetScript("OnMouseWheel", function(_, d)
        ui.offset = math.max(0, math.min(math.max(0, #rows - B.ROWS), ui.offset - d))
        AH().Refresh()
    end)
    for i = 1, B.ROWS do
        local r = makeRow(ui, 38)
        r:SetScript("OnClick", function(self, button)
            if not self.r then return end
            if button == "RightButton" then B.Never(self.r.itemID) else B.Click(self.r) end
        end)
        r:SetScript("OnEnter", function(self)
            if GameTooltip and self.r then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("item:" .. self.r.itemID); GameTooltip:Show()
            end
        end)
        ui.sRows[i] = r
    end
    local all = CreateFrame("Button", "OneMoreQuestAuctionBuyAll", ui)
    all:SetSize(348, 44)
    all.bg = all:CreateTexture(nil, "BACKGROUND"); all.bg:SetAllPoints(); all.bg:SetColorTexture(0.165, 0.141, 0.086, 1)
    all.price = fs(all, "GameFontNormal", 0.95, 0.82, 0.48); all.price:SetPoint("RIGHT", -10, 0); all.price:SetJustifyH("RIGHT")
    all.title = fs(all, "GameFontNormalLarge", 0.95, 0.82, 0.48)          -- one big line, no small text (decision 271)
    all.title:SetPoint("LEFT", 10, 0); all.title:SetPoint("RIGHT", all.price, "LEFT", -8, 0)
    all.flash = all:CreateTexture(nil, "ARTWORK"); all.flash:SetAllPoints(); all.flash:SetColorTexture(0.25, 0.85, 0.35, 0.3); all.flash:Hide()
    all:SetScript("OnClick", function() B.FillNext() end)
    ui.all = all
    ui.hint = fs(ui, "GameFontDisableSmall"); ui.hint:SetWidth(270)
    -- bottom right: bring back the consumables clicked away (decision 275)
    local reset = CreateFrame("Button", "OneMoreQuestAuctionBuyReset", ui)
    reset:SetSize(70, 20)
    reset.edge = reset:CreateTexture(nil, "BACKGROUND"); reset.edge:SetPoint("TOPLEFT", -1, 1); reset.edge:SetPoint("BOTTOMRIGHT", 1, -1)
    reset.edge:SetColorTexture(0.45, 0.37, 0.18, 1)
    reset.bg = reset:CreateTexture(nil, "BORDER"); reset.bg:SetAllPoints(); reset.bg:SetColorTexture(0.2, 0.21, 0.25, 1)
    reset.text = fs(reset, "GameFontNormalSmall", 0.93, 0.93, 0.95); reset.text:SetPoint("CENTER"); reset.text:SetText("Reset")
    reset.hl = reset:CreateTexture(nil, "HIGHLIGHT"); reset.hl:SetAllPoints(); reset.hl:SetColorTexture(1, 1, 1, 0.08)
    reset:SetScript("OnClick", function() B.ResetNever() end)
    reset:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Reset")
        local n = B.NeverCount()
        GameTooltip:AddLine("All consumables you clicked away (right click) come back to the list.", 1, 1, 1, true)
        GameTooltip:AddLine(n > 0 and (n .. " clicked away right now") or "Nothing clicked away right now", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    reset:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    ui.reset = reset
    -- the weapon scan button stands where the result would (decision 290)
    local wScan = CreateFrame("Button", nil, ui)
    wScan:SetSize(348, 24)
    wScan.bg = wScan:CreateTexture(nil, "BACKGROUND"); wScan.bg:SetAllPoints(); wScan.bg:SetColorTexture(0.165, 0.141, 0.086, 1)
    wScan.hl = wScan:CreateTexture(nil, "HIGHLIGHT"); wScan.hl:SetAllPoints(); wScan.hl:SetColorTexture(1, 1, 1, 0.06)
    wScan.text = fs(wScan, "GameFontNormalSmall", 0.95, 0.82, 0.48); wScan.text:SetPoint("CENTER"); wScan.text:SetText("Scan for weapon upgrades")
    wScan:SetScript("OnClick", function() B.ScanWeapons() end)
    ui.wScan = wScan
    ui.wNote = fs(ui, "GameFontDisableSmall")
    ui.gTitle = fs(ui, "GameFontNormal", 0.95, 0.82, 0.48); ui.gTitle:SetText("Bags")
    local gScan = CreateFrame("Button", nil, ui)
    gScan:SetSize(348, 24)
    gScan.bg = gScan:CreateTexture(nil, "BACKGROUND"); gScan.bg:SetAllPoints(); gScan.bg:SetColorTexture(0.165, 0.141, 0.086, 1)
    gScan.hl = gScan:CreateTexture(nil, "HIGHLIGHT"); gScan.hl:SetAllPoints(); gScan.hl:SetColorTexture(1, 1, 1, 0.06)
    gScan.text = fs(gScan, "GameFontNormalSmall", 0.95, 0.82, 0.48); gScan.text:SetPoint("CENTER"); gScan.text:SetText("Scan for bigger bags")
    gScan:SetScript("OnClick", function() B.ScanBags() end)
    ui.gScan = gScan
    ui.gNote = fs(ui, "GameFontDisableSmall")
    ui.gRows = {}
    for i = 1, B.BAG_ROWS do
        local r = makeRow(ui, 38)
        r:SetScript("OnClick", function(self, button)
            if not self.g then return end
            if button == "RightButton" then B.Never(self.g.itemID) else B.Buy(self.g, 1) end
        end)
        r:SetScript("OnEnter", function(self)
            if GameTooltip and self.g then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink("item:" .. self.g.itemID); GameTooltip:Show() end
        end)
        ui.gRows[i] = r
    end
    ui.more = fs(ui, "GameFontDisableSmall")
end
B._UI = function() return ui end


-- draws the buy view below `top` and returns the height it needs
function B.Render(panel, top)
    if not ui then build(panel) end
    ui:ClearAllPoints(); ui:SetPoint("TOPLEFT", 0, -top); ui:SetPoint("BOTTOMRIGHT")
    ui:Show()
    local SC = OMQ.Score
    local class = SC and SC.MyClass() or select(2, UnitClass("player"))
    local cname = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class or "?"
    ui.head:SetText(string.format("For your %s, level %d - you carry |cfff2d27a%s|r", cname, level(), money(GetMoney and GetMoney() or 0)))
    local y = 26
    -- weapons
    local W = B.Weapons()
    ui.wTitle:ClearAllPoints(); ui.wTitle:SetPoint("TOPLEFT", 16, -y)
    y = y + 20
    local wText
    ui.wScan:SetShown(not B.want.weapons)
    ui.wScan:ClearAllPoints(); ui.wScan:SetPoint("TOPLEFT", 16, -y)
    if not B.want.weapons then wText = ""; y = y + 28
    elseif browse.state ~= "done" then wText = "Looking at the weapons..."
    else
        local pending = false
        for _, c in ipairs(candidates) do if c.state == "price" then pending = true end end
        if pending then wText = "Looking at the weapons..." elseif #W == 0 then wText = "No upgrade on sale right now" end
    end
    for i, r in ipairs(ui.wRows) do
        local w = W[i]
        r.w = w
        r:SetShown(w ~= nil)
        if w then
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 16, -y)
            local name, _, quality, _, minLevel, _, sub, _, _, icon = info(w.offer.link)
            r.icon:SetTexture(icon)
            r.name:SetText(name or ("item " .. w.itemID)); r.name:SetTextColor(qColor(quality))
            r.sub:SetText((sub or "") .. (minLevel and (" - level " .. minLevel) or ""))
            r.top:SetText("|cff40e060+" .. w.gain .. " score|r")
            r.bottom:SetText(w.bought and "Bought" or money(w.offer.buyout))
            y = y + 44
        end
    end
    ui.wNote:ClearAllPoints(); ui.wNote:SetPoint("TOPLEFT", 16, -y)
    ui.wNote:SetText(wText or "")
    if wText then y = y + 18 end
    -- bags (decision 265)
    -- the section is always there (decision 320): title, the scan button or what the scan found
    local G = B.Bags()
    ui.gTitle:ClearAllPoints(); ui.gTitle:SetPoint("TOPLEFT", 16, -(y + 4))
    ui.gTitle:Show()
    y = y + 24
    ui.gScan:SetShown(not B.want.bags)
    ui.gScan:ClearAllPoints(); ui.gScan:SetPoint("TOPLEFT", 16, -y)
    local gText
    if not B.want.bags then y = y + 28
    else
        local pricing = false
        for _, c in ipairs(bagCands) do if c.state == "price" then pricing = true end end
        local st = bagBrowse.stats or {}
        if bagBrowse.state == "loading" then
            gText = string.format("Loading %d bags...", st.unread or 0)
        elseif bagBrowse.state ~= "done" then
            gText = "Looking at the bags..."
        elseif pricing then
            local n, left = #bagCands, 0
            for _, c in ipairs(bagCands) do if c.state == "price" then left = left + 1 end end
            gText = string.format("Checking prices %d/%d...", n - left, n)
        elseif #G == 0 then
            gText = "No bigger bag on sale right now"
            if (st.unread or 0) > 0 then gText = gText .. " (" .. st.unread .. " could not be read)" end
        elseif (B.bagsMore or 0) > 0 then
            gText = string.format("and %d more bag types", B.bagsMore)
        end
    end
    for i, r in ipairs(ui.gRows) do
        local g = G[i]
        r.g = g
        r:SetShown(g ~= nil)
        if g then
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 16, -y)
            local name, _, quality, _, _, _, _, _, _, icon = info(g.itemID)
            r.icon:SetTexture(icon or select(5, instant(g.itemID)))
            r.name:SetText(name or ("item " .. g.itemID)); r.name:SetTextColor(qColor(quality))
            local what = B.KindLabel(g.bagKind) or "bag"
            r.sub:SetText(g.replaces == 0 and (what .. " - an empty bag slot") or string.format("%s - instead of %d slots", what, g.replaces))
            r.top:SetText("|cff40e060" .. g.slots .. " slots|r")
            r.bottom:SetText((buying and buying.row == g) and "Buying..." or (g.bought and "Bought") or money0(B.Cost(g, 1)))
            y = y + 40
        end
    end
    ui.gNote:ClearAllPoints(); ui.gNote:SetPoint("TOPLEFT", 16, -y)
    ui.gNote:SetText(gText or "")
    if gText then y = y + 18 end
    -- stock
    y = y + 6
    ui.sTitle:ClearAllPoints(); ui.sTitle:SetPoint("TOPLEFT", 16, -y)
    y = y + 20
    ui.offset = math.min(ui.offset, math.max(0, #rows - B.ROWS))
    local single = B.Mode() == "single"
    local clicks, total = 0, 0
    for _, r in ipairs(rows) do
        if (r.need or 0) > 0 and r.offers and #r.offers > 0 then
            clicks = clicks + 1
            total = total + B.Cost(r, r.need)
        end
    end
    for i, row in ipairs(ui.sRows) do
        local r = rows[i + ui.offset]
        row.r = r
        row:SetShown(r ~= nil)
        if r then
            row:ClearAllPoints(); row:SetPoint("TOPLEFT", 16, -y)
            local name, _, quality, _, _, _, _, _, _, icon = info(r.itemID)
            if not name and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, r.itemID) end
            row.icon:SetTexture(icon or select(5, instant(r.itemID)))
            -- the cheapest XP food says so behind its name (decision 272)
            row.name:SetText((name or ("item " .. r.itemID)) .. (r.xp and " (Cheapest 5% Buff)" or "")); row.name:SetTextColor(qColor(quality))
            local unit = r.offers and r.offers[1] and r.offers[1].unit
            -- no category line any more (decision 270): only what helps to choose
            local parts = {}
            if unit then parts[#parts + 1] = money(unit) .. " each" end
            if r.cheaper then parts[#parts + 1] = "weaker, cheaper" end
            if r.mine then parts[#parts + 1] = "you use it" end
            row.sub:SetText(table.concat(parts, " - "))
            local full = (r.need or 0) == 0
            row.top:SetText(string.format("%s%d / %d|r", full and "|cff9fdc8a" or "|cffe5e3dc", r.have or 0, r.target))
            local right
            if buying and buying.row == r then right = "Buying..."
            elseif r.state == "price" then right = "..."
            elseif r.state == "none" then right = "not on sale"
            elseif single then right = "Buy 1 - " .. money0(B.Cost(r, 1))
            elseif full then right = "stocked"
            else right = string.format("Buy %d - %s", r.need, money0(B.Cost(r, r.need))) end
            row.bottom:SetText(right)
            row.bg:SetAlpha((full and not single) and 0.5 or 1)
            y = y + 40
        end
    end
    if #rows > B.ROWS then
        ui.more:ClearAllPoints(); ui.more:SetPoint("TOPLEFT", 16, -y)
        ui.more:SetText(string.format("Mouse wheel: %d more", #rows - B.ROWS)); ui.more:Show()
        y = y + 16
    else ui.more:Hide() end
    -- fill everything up (fill mode)
    ui.all:SetShown(not single)
    if not single then
        y = y + 6
        ui.all:ClearAllPoints(); ui.all:SetPoint("TOPLEFT", 16, -y)
        ui.all.flash:SetShown(not buying and AH().Flashing())
        ui.all.title:SetText((buying and "Buying...") or clicks > 0 and string.format("Fill all Consumables - Click %d time%s", clicks, clicks == 1 and "" or "s")
            or "All Consumables stocked up")
        ui.all.price:SetText(clicks > 0 and money(total) or "")
        y = y + 48
    end
    ui.hint:ClearAllPoints(); ui.hint:SetPoint("TOPLEFT", 16, -(y + 4))
    ui.reset:ClearAllPoints(); ui.reset:SetPoint("TOPRIGHT", ui, "TOPLEFT", 364, -y)
    ui.hint:SetText(single and "Left click: buy one - right click: never suggest it"
        or "Left click: buy what is missing - right click: never suggest it")
    return y + 24
end

function B.Hide() if ui then ui:Hide() end end
