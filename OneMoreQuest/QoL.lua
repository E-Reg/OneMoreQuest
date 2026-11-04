-- One More Quest: quality of life at vendors
-- When a merchant window opens:
--   1. repair everything (if the merchant can repair)
--   2. sell all grey items
--   3. mana classes from level 10 (not mages: they conjure it): buy the best water this merchant offers, up to 20 pieces
--   4. hunters: fill the free room of the quiver / ammo pouch with arrows (bow, crossbow) or bullets (gun)
-- Each part can be switched with /omq qol repair|junk|water|ammo.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local WATER_TARGET = 20
local NO_MANA = { WARRIOR = true, ROGUE = true }

-- Classic water, worst to best. The merchant's own "usable" flag decides which
-- one the player is allowed to drink.
local WATER = { 159, 1179, 1205, 1708, 1645, 8766 }
local WATER_RANK = {}
for i, id in ipairs(WATER) do WATER_RANK[id] = i end

local Q = {}
OMQ.QoL = Q

local function isSecret(v) return issecretvalue and issecretvalue(v) end

local function on(part)
    local o = OMQ.db and OMQ.db.options and OMQ.db.options.qol
    return OMQ:Master("vendor") and (not o or o[part] ~= false)
end

local function money(copper)
    copper = math.floor(copper or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "g" end
    if s > 0 then t[#t + 1] = s .. "s" end
    if c > 0 or #t == 0 then t[#t + 1] = c .. "c" end
    return table.concat(t, " ")
end

local function itemCount(id)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id) or 0 end
    if GetItemCount then return GetItemCount(id) or 0 end
    return 0
end

local function sellPrice(link)
    if C_Item and C_Item.GetItemInfo then
        local _, _, _, _, _, _, _, _, _, _, price = C_Item.GetItemInfo(link)
        return price
    end
    if GetItemInfo then return select(11, GetItemInfo(link)) end
end

----------------------------------------------------------------------
-- 1. Repair
----------------------------------------------------------------------
function Q:Repair()
    if not (CanMerchantRepair and CanMerchantRepair()) then return end
    local cost, canRepair = GetRepairAllCost()
    if not (canRepair and type(cost) == "number" and cost > 0) then return end
    if cost > (GetMoney() or 0) then
        OMQ:Print("repair: not enough money (" .. money(cost) .. ")")
        return
    end
    RepairAllItems()
    OMQ:Print("repaired everything for " .. money(cost))
end

----------------------------------------------------------------------
-- 2. Junk
----------------------------------------------------------------------
function Q:SellJunk()
    local C = C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo and C.UseContainerItem) then return end
    local sold, total = 0, 0
    for bag = 0, OMQ.LastBag() do
        for slot = 1, C.GetContainerNumSlots(bag) or 0 do
            local info = C.GetContainerItemInfo(bag, slot)
            local ahLow = info and info.itemID and OMQ.AuctionHelper and OMQ.AuctionHelper.VendorIt(info.itemID)   -- decision 259
            if info and not isSecret(info.quality) and (info.quality == 0 or ahLow) and not info.hasNoValue then
                local per = info.hyperlink and sellPrice(info.hyperlink) or 0
                C.UseContainerItem(bag, slot)
                sold = sold + 1
                total = total + (per or 0) * (info.stackCount or 1)
            end
        end
    end
end

----------------------------------------------------------------------
-- 3. Water
----------------------------------------------------------------------
-- price, pieces per purchase, stock (-1 = unlimited), usable
local function merchantInfo(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local t = C_MerchantFrame.GetItemInfo(i)
        if type(t) == "table" then
            if t.hasExtendedCost then return nil end
            return t.price, t.stackCount, t.numAvailable, t.isUsable
        end
    end
    if GetMerchantItemInfo then
        local _, _, price, qty, avail, usable, extended = GetMerchantItemInfo(i)
        if extended then return nil end
        return price, qty, avail, usable
    end
end

local function itemIdOfLink(link)
    return link and tonumber(tostring(link):match("item:(%d+)"))
end

Q.WATER_MIN_LEVEL = 10          -- before level 10 buying water costs too much and is not needed (decision 220)

function Q:BuyWater()
    local _, class = UnitClass("player")
    if NO_MANA[class] then return end
    if class == "MAGE" then return end            -- mages conjure their water (decision 280)
    if (UnitLevel("player") or 1) < Q.WATER_MIN_LEVEL then return end
    if not (GetMerchantNumItems and GetMerchantItemLink and BuyMerchantItem) then return end
    local best, bestIndex
    for i = 1, GetMerchantNumItems() do
        local id = itemIdOfLink(GetMerchantItemLink(i))
        local rank = id and WATER_RANK[id]
        if rank then
            local price, qty, avail, usable = merchantInfo(i)
            -- an item with a limited stock of 0 cannot be bought
            if price and usable ~= false and avail ~= 0 and (not best or rank > best.rank) then
                best = { rank = rank, id = id, price = price or 0, qty = (qty and qty > 0) and qty or 1 }
                bestIndex = i
            end
        end
    end
    if not best then return end
    local want = WATER_TARGET - itemCount(best.id)
    if want <= 0 then return end
    local unit = best.price / best.qty
    local affordable = unit > 0 and math.floor((GetMoney() or 0) / unit) or want
    local buy = math.min(want, affordable)
    if buy <= 0 then OMQ:Print("water: not enough money"); return end
    local maxStack = (GetMerchantItemMaxStack and GetMerchantItemMaxStack(bestIndex)) or 20
    if maxStack < 1 then maxStack = 20 end
    local bought = 0
    while bought < buy do
        local n = math.min(maxStack, buy - bought)
        BuyMerchantItem(bestIndex, n)
        bought = bought + n
    end
end

----------------------------------------------------------------------
-- 4. Ammo (hunters)
----------------------------------------------------------------------
local CLASS_WEAPON, CLASS_PROJECTILE, CLASS_QUIVER = 2, 6, 11
-- ranged weapon subclass -> ammo subclass (also the quiver subclass: 2 quiver, 3 ammo pouch)
local AMMO_FOR_WEAPON = { [2] = 2, [18] = 2, [3] = 3 }   -- bow, crossbow -> arrows; gun -> bullets

local function instant(x)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local id, _, _, _, _, classID, subClassID = f(x)
    if not id then return nil end
    return id, classID, subClassID
end

-- which ammo does the equipped ranged weapon take? (subclass of the ammo, or nil)
local function neededAmmo()
    local id = GetInventoryItemID and GetInventoryItemID("player", 18)
    if not id then return nil end
    local _, classID, subClassID = instant(id)
    if classID ~= CLASS_WEAPON then return nil end
    return AMMO_FOR_WEAPON[subClassID]
end

-- how many pieces of this ammo still fit: the free room in all quivers / ammo pouches of the right kind
-- (decision 221). Empty slots take a full stack, slots with this ammo the rest of their stack. Hunters
-- always have a quiver or pouch; without one (or when it cannot be read) nothing is bought.
local AMMO_STACK = 200        -- fallback when the game does not tell the stack size
local function stackSize(id)
    if C_Item and C_Item.GetItemMaxStackSizeByID then
        local ok, n = pcall(C_Item.GetItemMaxStackSizeByID, id)
        if ok and type(n) == "number" and n > 0 and not isSecret(n) then return n end
    end
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if info then
        local ok, _, _, _, _, _, _, _, n = pcall(info, id)
        if ok and type(n) == "number" and n > 0 and not isSecret(n) then return n end
    end
    return AMMO_STACK
end
Q._stackSize = stackSize

local function ammoRoom(ammoSub, itemId)
    local C = C_Container
    if not (C and C.ContainerIDToInventoryID and C.GetContainerNumSlots and GetInventoryItemID) then return 0, false end
    local stack = itemId and stackSize(itemId) or AMMO_STACK
    local room, found = 0, false
    for bag = 1, (NUM_BAG_SLOTS or 4) do
        local inv = C.ContainerIDToInventoryID(bag)
        local id = inv and GetInventoryItemID("player", inv)
        if id then
            local _, classID, subClassID = instant(id)
            if classID == CLASS_QUIVER and subClassID == ammoSub then
                found = true
                for slot = 1, C.GetContainerNumSlots(bag) or 0 do
                    local info = C.GetContainerItemInfo and C.GetContainerItemInfo(bag, slot)
                    if not info or not info.itemID then
                        room = room + stack
                    elseif info.itemID == itemId then
                        room = room + math.max(0, stack - (info.stackCount or 0))
                    end
                end
            end
        end
    end
    return room, found
end
Q._ammoRoom = ammoRoom

-- for the diagnostics: the size of all quivers of the right kind in pieces
local function ammoCapacity(ammoSub)
    local C = C_Container
    local total = 0
    if C and C.ContainerIDToInventoryID and C.GetContainerNumSlots and GetInventoryItemID then
        for bag = 1, (NUM_BAG_SLOTS or 4) do
            local inv = C.ContainerIDToInventoryID(bag)
            local id = inv and GetInventoryItemID("player", inv)
            if id then
                local _, classID, subClassID = instant(id)
                if classID == CLASS_QUIVER and subClassID == ammoSub then
                    total = total + (C.GetContainerNumSlots(bag) or 0) * AMMO_STACK
                end
            end
        end
    end
    return total
end

-- pieces of this kind of ammo I carry (any arrows, or any bullets)
local function ammoOnHand(ammoSub)
    local C = C_Container
    local have = 0
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then return 0 end
    for bag = 0, OMQ.LastBag() do
        for slot = 1, C.GetContainerNumSlots(bag) or 0 do
            local info = C.GetContainerItemInfo(bag, slot)
            if info and type(info.itemID) == "number" and not isSecret(info.itemID) then
                local _, classID, subClassID = instant(info.itemID)
                if classID == CLASS_PROJECTILE and subClassID == ammoSub then
                    have = have + (info.stackCount or 1)
                end
            end
        end
    end
    return have
end

-- for the low ammo alert: ammo subclass (2 arrows, 3 bullets) the ranged weapon takes and the pieces carried
function Q:AmmoStatus()
    local _, class = UnitClass("player")
    if class ~= "HUNTER" then return nil end
    local sub = neededAmmo()
    if not sub then return nil end
    return sub, ammoOnHand(sub)
end

function Q:BuyAmmo()
    local _, class = UnitClass("player")
    if class ~= "HUNTER" then return end
    if not (GetMerchantNumItems and GetMerchantItemLink and BuyMerchantItem) then return end
    local ammoSub = neededAmmo()
    if not ammoSub then return end
    -- the dearest usable ammo of the right kind (better ammo costs more)
    local best, bestIndex
    for i = 1, GetMerchantNumItems() do
        local link = GetMerchantItemLink(i)
        local id, classID, subClassID = instant(link)
        if id and classID == CLASS_PROJECTILE and subClassID == ammoSub then
            local price, qty, avail, usable = merchantInfo(i)
            if price and usable ~= false and avail ~= 0 then
                qty = (qty and qty > 0) and qty or 1
                local unit = price / qty
                if not best or unit > best.unit then
                    best = { id = id, unit = unit, qty = qty, avail = avail }
                    bestIndex = i
                end
            end
        end
    end
    if not best then return end
    -- only what really fits into the quiver: whole packs, never more (decision 221)
    local want = ammoRoom(ammoSub, best.id)
    if want <= 0 then return end
    local packs = math.floor(want / best.qty)
    if best.avail and best.avail > 0 then packs = math.min(packs, best.avail) end
    local affordable = best.unit > 0 and math.floor((GetMoney() or 0) / (best.unit * best.qty)) or packs
    packs = math.min(packs, affordable)
    if packs <= 0 then
        if affordable <= 0 then OMQ:Print("ammo: not enough money") end
        return
    end
    local pieces = packs * best.qty
    local maxStack = (GetMerchantItemMaxStack and GetMerchantItemMaxStack(bestIndex)) or 200
    if maxStack < 1 then maxStack = 200 end
    -- buy in whole packs, at most a stack per call
    local per = math.max(best.qty, math.floor(maxStack / best.qty) * best.qty)
    local bought = 0
    while bought < pieces do
        local n = math.min(per, pieces - bought)
        BuyMerchantItem(bestIndex, n)
        bought = bought + n
    end
end

-- /omq diag for hunters: shows step by step what the ammo purchase sees
function Q:AmmoLines()
    local out = {}
    local function add(t) out[#out + 1] = t end
    local _, class = UnitClass("player")
    if class ~= "HUNTER" then return out end
    local function s3(...) local a, b, c = ...; return tostring(a) .. "/" .. tostring(b) .. "/" .. tostring(c) end
    add("ammo: option " .. (on("ammo") and "on" or "off") .. ", GetItemInfoInstant " ..
        tostring((C_Item and C_Item.GetItemInfoInstant ~= nil) or GetItemInfoInstant ~= nil))
    local w = GetInventoryItemID and GetInventoryItemID("player", 18)
    add("ammo: ranged slot 18 item " .. tostring(w) .. " (id/class/subclass " .. s3(instant(w or 0)) .. ")")
    local need = neededAmmo()
    add("ammo: needed ammo subclass " .. tostring(need) .. " (2 arrows, 3 bullets)")
    local C = C_Container
    for bag = 1, (NUM_BAG_SLOTS or 4) do
        local inv = C and C.ContainerIDToInventoryID and C.ContainerIDToInventoryID(bag)
        local id = inv and GetInventoryItemID("player", inv)
        if id then
            add(string.format("ammo: bag %d inv %s item %s (id/class/subclass %s) slots %s", bag, tostring(inv), tostring(id),
                s3(instant(id)), tostring(C.GetContainerNumSlots and C.GetContainerNumSlots(bag))))
        end
    end
    if need then
        add("ammo: capacity " .. ammoCapacity(need) .. ", on hand " .. ammoOnHand(need))
    end
    local n = GetMerchantNumItems and GetMerchantNumItems() or 0
    add("ammo: merchant items " .. tostring(n) .. (n == 0 and " (open a merchant window first)" or ""))
    for i = 1, n do
        local id, c, sc = instant(GetMerchantItemLink(i))
        if c == CLASS_PROJECTILE or c == CLASS_QUIVER then
            local price, qty, avail, usable = merchantInfo(i)
            add(string.format("  %d: item %s class/sub %s/%s price %s qty %s stock %s usable %s", i, tostring(id), tostring(c),
                tostring(sc), tostring(price), tostring(qty), tostring(avail), tostring(usable)))
        end
    end
    return out
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local function onMerchant()
    local function run(part, fn)
        if not on(part) then return end
        local ok, err = pcall(fn, Q)
        if not ok then OMQ:Error("qol " .. part, err) end
    end
    run("repair", Q.Repair)
    run("junk", Q.SellJunk)
    -- let the money of the sale arrive before the water is bought
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, function() run("water", Q.BuyWater); run("ammo", Q.BuyAmmo) end)
    else
        run("water", Q.BuyWater)
        run("ammo", Q.BuyAmmo)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:SetScript("OnEvent", function() onMerchant() end)

OMQ:RegisterCommand("qol", function(arg)
    local o = OMQ.db.options.qol
    local part = (arg or ""):lower()
    if part == "repair" or part == "junk" or part == "water" or part == "ammo" or part == "flight" then
        o[part] = not (o[part] ~= false)
        OMQ:Print("qol " .. part .. ": " .. (o[part] and "on" or "off"))
        return
    end
    OMQ:Print(string.format("repair %s, sell grey items %s, buy water %s, buy ammo %s, follow group flights %s",
        on("repair") and "on" or "off", on("junk") and "on" or "off", on("water") and "on" or "off", on("ammo") and "on" or "off",
        on("flight") and "on" or "off"))
    print("  /omq qol repair | junk | water | ammo | flight  (toggle)")
end, "vendor helpers: auto repair, sell grey items, buy water, buy ammo, follow group flights")
