-- One More Quest: Auction Helper (decision 259)
-- Opens with the auction house: what in my bags is worth more there than at the vendor, posted with
-- one click per auction (the game wants a click or key press for every post).
--   Fast mode (default): "You get about 4g 20s more than at the vendor - 9 clicks"; each left click
--     posts the next item, a right click skips it. A skipped item stays out of the fast mode until it
--     is posted in the select mode.
--   Select mode: one row per item with picture, prices and gain; left click posts, right click skips.
--   Unsold twice in a row (the game's mails tell): off the fast list like a skip (decision 261).
-- What counts: every item from white up that can be sold on the auction house (not bound) - potions,
-- food, trade goods, recipes, gear (decision 260); the worth rule filters the rest. Left out: quest
-- items, ammo, profession tools (decision 277), the drinks and class supplies of the Group Check and a gear upgrade for me.
-- A material that a dad needs for a recipe (Needs.lua) is sold like anything else since decision 301.
-- Price: the current lowest price, not undercut. No price on the auction house: stays in the bag.
-- Worth it: price x quantity - 5% cut is at least 5% above the vendor price. The deposit does not count:
-- it comes back when the item sells (decision 273).
-- Always 24 hours; commodities with everything I carry of them, gear one by one.
-- Consumables of my buy list (decision 274) never go to the fast list. The select list offers them as
-- "sell all" and, when I carry more than the fill-up target, also "keep <target>" (sells the rest).
-- Trade goods that are not worth it (a price, but under +5%) are remembered for 3 days; "sell grey
-- items" sells them at the next vendor too. White items of any kind that are not worth it go the same
-- way, but only on the day my own scan saw that price (decision 276); my buy-list consumables never do.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local AH = {}
OMQ.AuctionHelper = AH

AH.CUT, AH.MARGIN, AH.DURATION = 0.05, 1.05, 2          -- duration index 2 = 24 hours
AH.PRICE_TTL, AH.QUERY_TIMEOUT, AH.LOW_DAYS = 300, 4, 3
AH.ROWS = 12
-- speed (decision 293): clicks go first - no new search for QUIET seconds after a click; prices of up to
-- BATCH items come with one request (C_AuctionHouse.SearchForItemKeys), the single search stays the fallback
AH.QUIET, AH.BATCH, AH.READY_FLASH = 3, 40, 0.6
AH.HEAD = 108           -- the tabs and the box with the mode switch on top (decisions 264 and 267)

local GOLD = { 0.89, 0.71, 0.29 }
local function isSecret(v) return issecretvalue and issecretvalue(v) end
local function now() return GetTime() end
local CA = function() return C_AuctionHouse end

local function money(c)
    c = math.floor(c or 0)
    local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "g" end
    if s > 0 then t[#t + 1] = s .. "s" end
    if (cc > 0 and g == 0) or #t == 0 then t[#t + 1] = cc .. "c" end
    return table.concat(t, " ")
end
AH.Money = money

local function db()
    OMQDB.ah = OMQDB.ah or {}
    OMQDB.ah.skip = OMQDB.ah.skip or {}
    OMQDB.ah.low = OMQDB.ah.low or {}
    OMQDB.ah.lowDay = OMQDB.ah.lowDay or {}   -- white items not worth it: item ID -> the day of my scan (decision 276)
    OMQDB.ah.names = OMQDB.ah.names or {}      -- item name as the game writes it -> item ID (for the mails)
    OMQDB.ah.fails = OMQDB.ah.fails or {}      -- item ID -> unsold auctions in a row
    OMQDB.ah.mails = OMQDB.ah.mails or {}      -- mails already counted -> time
    OMQDB.ah.worth = OMQDB.ah.worth or {}      -- item ID -> worth the auction house at my last scan (decision 292)
    return OMQDB.ah
end
function AH.Enabled()
    local o = OMQ.db and OMQ.db.options
    return o and o.ahHelper ~= false and OMQ:Master("vendor")
end
function AH.Mode()
    local o = OMQ.db and OMQ.db.options
    return (o and o.ahMode == "select") and "select" or "fast"
end
function AH.SetMode(m)
    OMQ.db.options.ahMode = (m == "select") and "select" or "fast"
    AH.Refresh()
end

----------------------------------------------------------------------
-- Bags: the candidates
----------------------------------------------------------------------
local panel             -- the helper's frame (built on the first open)
local entries = {}         -- the current list
local prices = {}          -- key -> { price = copper or false, at }
AH._entries, AH._prices = entries, prices

local function instant(id)
    if C_Item and C_Item.GetItemInfoInstant then return C_Item.GetItemInfoInstant(id) end
    if GetItemInfoInstant then return GetItemInfoInstant(id) end
end
local function info(x)
    if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(x) end
    if GetItemInfo then return GetItemInfo(x) end
end
local function location(bag, slot)
    if ItemLocation and ItemLocation.CreateFromBagAndSlot then return ItemLocation:CreateFromBagAndSlot(bag, slot) end
    return { bagID = bag, slotIndex = slot }
end
local function isCommodity(loc)
    local C = CA()
    if not (C and C.GetItemCommodityStatus) then return false end
    local ok, s = pcall(C.GetItemCommodityStatus, loc)
    local COMM = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2
    return ok and s == COMM
end
local function keyString(k)
    if type(k) ~= "table" then return tostring(k) end
    return (k.itemID or 0) .. ":" .. (k.itemLevel or 0) .. ":" .. (k.itemSuffix or 0)
end

-- a dad (or I) needs the material for a recipe
local function needed(itemID)
    local N = OMQ.Needs
    if not (N and N.Ask) then return false end
    local ok, r = pcall(N.Ask, N, itemID)
    return ok and r and r.order and #r.order > 0 or false
end
-- a piece of gear that would be an upgrade for me
local function upgradeForMe(link, equipLoc)
    local LP = OMQ.LootPreview
    if not (LP and LP.Gain and equipLoc and equipLoc ~= "") then return false end
    local ok, g = pcall(LP.Gain, link, equipLoc)
    return ok and g and g > 0 or false
end

AH.UpgradeForMe, AH.Needed = upgradeForMe, needed     -- the vendor helper asks the same (decision 292)

-- profession tools are never sold (decision 277): the tools of the profession card (Alerts/Rules.lua)
-- and a few more that some recipes or skills ask for
AH.TOOL_EXTRA = { 6219, 10498, 5060, 9149 }   -- Arclight Spanner, Gyromatic Micro-Adjustor, Thieves' Tools, Philosopher's Stone
function AH.IsTool(itemID)
    if not AH.toolSet then
        local t = {}
        for _, id in ipairs(AH.TOOL_EXTRA) do t[id] = true end
        local M = OMQ.Alerts
        for _, list in pairs(M and M.TOOLS or {}) do
            for _, tool in ipairs(list) do
                t[tool.item] = true
                for _, id in ipairs(tool.also or {}) do t[id] = true end
            end
        end
        if M and M.TOOLS then AH.toolSet = t end      -- built once the rules are loaded
        return t[itemID] or false
    end
    return AH.toolSet[itemID] or false
end

function AH.Scan()
    for i = #entries, 1, -1 do entries[i] = nil end
    local C = C_Container
    local A = CA()
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo and A) then return entries end
    local byId = {}
    for bag = 0, OMQ.LastBag() do
        for slot = 1, C.GetContainerNumSlots(bag) or 0 do
            local it = C.GetContainerItemInfo(bag, slot)
            if it and it.itemID and not isSecret(it.quality) and (it.quality or 0) >= 1 and not it.isBound then
                local loc = location(bag, slot)
                local _, _, _, equipLoc, icon, classID = instant(it.itemID)
                -- every white or better item (decision 260); not quest items, ammo, drinks and class supplies
                local keep = OMQ.Ready and OMQ.Ready.KEEP and OMQ.Ready.KEEP[it.itemID]
                local valid = A.IsSellItemValid and A.IsSellItemValid(loc, false)
                if classID ~= 12 and classID ~= 6 and not keep and not AH.IsTool(it.itemID) and valid ~= false then
                    local link = it.hyperlink
                    local name, _, quality, _, _, _, _, _, _, _, vendor = info(link or it.itemID)
                    local comm = isCommodity(loc)
                    if byId[it.itemID] and comm then
                        local e = byId[it.itemID]
                        e.qty = e.qty + (it.stackCount or 1)
                    else
                        local e = { itemID = it.itemID, bag = bag, slot = slot, loc = loc, link = link,
                                    name = name or it.itemName or ("item " .. it.itemID), quality = quality or it.quality,
                                    icon = it.iconFileID or icon, vendor = vendor or 0, qty = it.stackCount or 1,
                                    commodity = comm, equipLoc = equipLoc, classID = classID }
                        if comm then byId[it.itemID] = e end
                        -- a material a dad needs is sold like anything else (decision 301)
                        if upgradeForMe(link, equipLoc) then e.out = "upgrade" end
                        local k = A.GetItemKeyFromItem and A.GetItemKeyFromItem(loc)
                        e.itemKey = k or (A.MakeItemKey and A.MakeItemKey(it.itemID)) or { itemID = it.itemID }
                        e.key = comm and ("c" .. it.itemID) or ("i" .. keyString(e.itemKey))
                        entries[#entries + 1] = e
                    end
                end
            end
        end
    end
    -- what the game lets me post of a commodity (everything in the bags)
    for _, e in ipairs(entries) do
        if e.commodity and A.GetAvailablePostCount then
            local ok, n = pcall(A.GetAvailablePostCount, e.loc)
            if ok and type(n) == "number" and n > 0 then e.qty = n end
        end
    end
    -- consumables I use (decision 274): only by hand, all of them or what is over the fill-up target
    local B = OMQ.AuctionBuy
    for i = 1, #entries do
        local e = entries[i]
        local target = B and B.TargetFor and B.TargetFor(e.itemID)
        if target and not e.out then
            e.useful = target
            if e.commodity and e.qty > target then
                local k = {}
                for f, v in pairs(e) do k[f] = v end
                k.qty, k.keep, k.twin, e.twin = e.qty - target, target, e, k
                entries[#entries + 1] = k
            end
        end
    end
    AH.Evaluate()
    return entries
end

-- price and verdict of every entry
function AH.Evaluate()
    local A = CA()
    local skip = db().skip
    for _, e in ipairs(entries) do
        local p = prices[e.key]
        -- the dump of the whole house prices a commodity at once (decision 343)
        local D = OMQ.Prices
        if e.commodity and not e.posted and D and D.Session and D.Session() and (not p or p.at < (D.SessionAt() or 0)) then
            local dp = D.Auction(e.itemID)
            p = { price = dp or false, at = now() }
            prices[e.key] = p
        end
        e.skipped = skip[e.itemID] and true or false
        if e.out then e.state = e.out
        elseif not p or (now() - p.at > AH.PRICE_TTL and not e.posted) then e.state = "price"
        elseif not p.price then e.state = "noprice"
        else
            e.price = p.price
            local gross = e.commodity and e.price * e.qty or e.price
            local net = gross * (1 - AH.CUT)                      -- no deposit: it comes back with the sale (decision 273)
            local vend = (e.vendor or 0) * e.qty
            e.gain = math.floor(net - vend)
            e.income = math.floor(gross * (1 - AH.CUT))
            e.value = math.floor(gross)                         -- the listing value (decision 268)
            if not e.keep then db().worth[e.itemID] = (net >= vend * AH.MARGIN and net > vend) end   -- kept until the next scan (decision 292)
            if net >= vend * AH.MARGIN and net > vend then
                e.state = "ok"
                if not e.keep then db().low[e.itemID] = nil; db().lowDay[e.itemID] = nil end
            else
                e.state = "low"
                if e.keep or e.useful then                               -- my own consumables are never sold that way
                elseif e.classID == 7 then db().low[e.itemID] = time()   -- trade goods: for 3 days
                elseif e.quality == 1 then db().lowDay[e.itemID] = AH.Today() end   -- white items: today only (decision 276)
            end
        end
    end
    table.sort(entries, function(a, b)
        if (a.gain or -1) ~= (b.gain or -1) then return (a.gain or -1) > (b.gain or -1) end
        return a.itemID < b.itemID
    end)
end

-- the lists the panel shows
function AH.Lists()
    local fast, select, out, pending, total, income, value = {}, {}, {}, 0, 0, 0, 0
    for _, e in ipairs(entries) do
        if not e.posted and not (e.twin and e.twin.posted) then
            if e.state == "ok" then
                select[#select + 1] = e
                if not e.skipped and not e.useful then fast[#fast + 1] = e; total = total + e.gain; income = income + (e.income or 0); value = value + (e.value or 0) end
            elseif e.keep then                                -- the second way of a consumable: counted once
            elseif e.state == "price" then pending = pending + 1
            else out[#out + 1] = e end
        end
    end
    -- skipped ones at the end of the select list
    -- the two ways of one consumable stay together: "sell all" first, then "keep"
    local function g(e) return (e.keep and e.twin) and e.twin.gain or e.gain end
    table.sort(select, function(a, b)
        if a.skipped ~= b.skipped then return not a.skipped end
        if g(a) ~= g(b) then return g(a) > g(b) end
        if a.itemID ~= b.itemID then return a.itemID < b.itemID end
        return not a.keep and b.keep
    end)
    -- the whole round of the fast mode: still to post plus already posted since the auction house opened
    local r = AH.round
    local count = 0
    for _, e in ipairs(entries) do if not e.keep then count = count + 1 end end
    return { fast = fast, select = select, out = out, pending = pending, total = total, count = count,
             roundCount = #fast + r.n, roundIncome = income + r.income, roundValue = value + (r.value or 0) }
end

-- the calendar day, for prices I checked today myself (decision 276)
function AH.Today() return date and date("%Y-%m-%d") or "?" end

-- sold at the vendor with the grey items (QoL.lua): not worth the auction house lately, cannot be worn
function AH.VendorIt(itemID)
    local ah = OMQDB and OMQDB.ah
    if not ah then return false end
    if ah.lowDay and ah.lowDay[itemID] and ah.lowDay[itemID] == AH.Today() then return true end
    local t = ah.low and ah.low[itemID]
    return t and (time() - t) < AH.LOW_DAYS * 86400 or false
end

----------------------------------------------------------------------
-- Prices: one search at a time, as the game's throttle allows
----------------------------------------------------------------------
local asking = nil         -- the entry whose price is on the way
local askedAt = 0

local function sorts()
    local P = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
    return { { sortOrder = P, reverseSort = false } }
end

local function readPrice(e)
    local A = CA()
    if e.commodity then
        local n = A.GetNumCommoditySearchResults and A.GetNumCommoditySearchResults(e.itemID) or 0
        for i = 1, n do
            local r = A.GetCommoditySearchResultInfo(e.itemID, i)
            if r and r.unitPrice and r.unitPrice > 0 then return r.unitPrice end
        end
    else
        local n = A.GetNumItemSearchResults and A.GetNumItemSearchResults(e.itemKey) or 0
        for i = 1, n do
            local r = A.GetItemSearchResultInfo(e.itemKey, i)
            if r and r.buyoutAmount and r.buyoutAmount > 0 then return r.buyoutAmount end
        end
    end
    return false
end

local function gotPrice(e)
    if e.onResult then                                   -- a search of the buy mode (decision 264)
        local ok, err = pcall(e.onResult, e)
        if not ok then OMQ:Error("auction buy result", err) end
    else
        prices[e.key] = { price = readPrice(e), at = now() }
    end
    asking = nil
    AH.Evaluate()
    AH.Refresh()
    AH.Pump()
end

-- is a scan running? my own prices are on their way, or the buy mode's searches (decision 286)
function AH.Scanning()
    if not AH.open then return false end
    if asking then return true end
    if OMQ.Prices and OMQ.Prices.Busy() then return true end      -- the whole-house price scan (decision 341)
    local A = CA()
    if A and A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then return true end
    for _, e in ipairs(entries) do if e.state == "price" then return true end end
    local B = OMQ.AuctionBuy
    return (AH.view == "buy" and B and B.Pending and B.Pending()) and true or false
end
-- a click that does nothing because a scan runs says so in the chat (decision 289)
local lastNote = 0
function AH.WaitNote()
    if not AH.Scanning() then return end
    local t = now()
    if t - lastNote < 2 then return end
    lastNote = t
    OMQ:Print("auction helper: still scanning the auction house - please wait a moment")
end
local function paintScan()
    if panel and panel.scan then panel.scan:SetShown(AH.Scanning()) end
    -- while the whole house is read the panel is covered (decision 343)
    if panel and panel.veil then
        local busy = AH.open and OMQ.Prices and OMQ.Prices.Busy() or false
        if busy then panel.veil:Show() else panel.veil:Hide() end
    end
end
AH.PaintScan = paintScan

-- scan everything again (decision 290)
function AH.ScanAll()
    if not AH.open then return end
    if OMQ.Prices and OMQ.Prices.EndSession then OMQ.Prices.EndSession() end     -- live searches this time (decision 343)
    AH.Scan()
    if OMQ.AuctionBuy and OMQ.AuctionBuy.ScanAll then OMQ.AuctionBuy.ScanAll() end
    AH.Refresh()
    AH.Pump()
end

function AH.Pump()
    AH._pump()
    paintScan()
end
function AH.Quiet() AH.quietUntil = now() + AH.QUIET end
-- the next click is taken again: the buttons flash shortly (decision 293)
function AH.Ready()
    AH.readyAt = now()
    if C_Timer and C_Timer.After then C_Timer.After(AH.READY_FLASH + 0.05, function() AH.Refresh() end) end
end
function AH.Flashing() return AH.readyAt and now() - AH.readyAt < AH.READY_FLASH or false end

-- one request for many prices: the lowest price of every item key (decision 293)
local tried = {}                                         -- keys a batch already asked for (this visit)
AH._tried = tried
local function onBatch(q)
    local A = CA()
    if not q.answered then                               -- no answer: this client does not batch, one by one from now on
        AH.noBatch = true
        return
    end
    local byKey, byId = {}, {}
    for _, res in ipairs(A.GetBrowseResults and A.GetBrowseResults() or {}) do
        local k = res.itemKey
        if k and res.minPrice and res.minPrice > 0 then
            byKey[keyString(k)] = res
            local old = byId[k.itemID]
            if not old or res.minPrice < old.minPrice then byId[k.itemID] = res end
        end
    end
    local B = OMQ.AuctionBuy
    for _, e in ipairs(q.batch) do
        tried[e.key] = true
        local res = byKey[keyString(e.itemKey)] or (e.commodity and byId[e.itemID])
        if e.onResult ~= nil or e.kind then             -- a stock row of the buy mode
            if B and B.FromBatch then B.FromBatch(e, res) end
        elseif res then
            prices[e.key] = { price = res.minPrice, at = now() }
        elseif e.commodity then
            prices[e.key] = { price = false, at = now() }   -- nobody sells it
        end                                             -- a single item not found: asked on its own
    end
    if B and B.Build then B.Build() end
end
local function batchQuery()
    local A = CA()
    if AH.noBatch or not (A and A.SearchForItemKeys) then return nil end
    local list, keys = {}, {}
    for _, e in ipairs(entries) do
        if #list >= AH.BATCH then break end
        if e.state == "price" and not tried[e.key] and not e.keep then list[#list + 1] = e; keys[#keys + 1] = e.itemKey end
    end
    local B = OMQ.AuctionBuy
    if AH.view == "buy" and B and B.BatchRows then
        for _, r in ipairs(B.BatchRows()) do
            if #list >= AH.BATCH then break end
            list[#list + 1] = r; keys[#keys + 1] = r.itemKey
        end
    end
    if #list == 0 then return nil end
    return { browse = true, batch = list, key = "batch", onResult = onBatch, keys = keys }
end

function AH._pump()
    local A = CA()
    if not (A and A.SendSearchQuery) or not AH.open then return end
    if asking then
        if now() - askedAt < AH.QUERY_TIMEOUT then return end
        gotPrice(asking)                               -- no answer: read what is there
        return
    end
    if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then return end
    if AH.Busy() then return end                       -- a post or a purchase goes first (decision 281)
    if OMQ.Prices and OMQ.Prices.Busy() then return end   -- the price scan of the whole house owns the result list (decision 341)
    if now() < (AH.quietUntil or 0) then return end   -- the dad is clicking: no new search (decision 293)
    if OMQ.AuctionBuy and OMQ.AuctionBuy.UseDump then OMQ.AuctionBuy.UseDump() end   -- the dump answers what it can (decision 343)
    local bq = batchQuery()
    if bq then
        asking, askedAt = bq, now()
        A.SearchForItemKeys(bq.keys, sorts())
        return
    end
    for _, e in ipairs(entries) do
        if e.state == "price" then
            asking, askedAt = e, now()
            A.SendSearchQuery(e.itemKey, sorts(), true)
            return
        end
    end
    -- then the buy mode's searches: stock prices, the weapon browse, the weapon offers (decision 264)
    local q = AH.view == "buy" and OMQ.AuctionBuy and OMQ.AuctionBuy.NextQuery()      -- only once the buy tab is looked at (decision 290)
    if q then
        asking, askedAt = q, now()
        if q.browse then
            if A.SendBrowseQuery then A.SendBrowseQuery(q.query) else gotPrice(q) end
        else
            A.SendSearchQuery(q.itemKey, sorts(), true)
        end
    end
end
AH._KeyString = function(k) return keyString(k) end
AH._Asking = function() return asking, asking and (now() - askedAt) or 0 end      -- for /omq ah bags (decision 322)

----------------------------------------------------------------------
-- Posting (from a click: the game demands one)
----------------------------------------------------------------------
local pendingConfirm = nil  -- { entry, args } when the game asks for a confirmation
local posting = nil
local fastUI = nil          -- the fast mode's part of the panel (built below)
AH._state = function() return { confirm = pendingConfirm, posting = posting } end

AH.round = { n = 0, income = 0 }      -- auctions posted since the auction house opened (decision 263)
local function counted(e)
    if e.roundCounted then return end
    e.roundCounted = true
    AH.round.n, AH.round.income = AH.round.n + 1, AH.round.income + (e.income or 0)
    AH.round.value = (AH.round.value or 0) + (e.value or 0)
end

local function uncount(e)
    if not e.roundCounted then return end
    e.roundCounted = nil
    AH.round.n, AH.round.income = math.max(0, AH.round.n - 1), math.max(0, AH.round.income - (e.income or 0))
    AH.round.value = math.max(0, (AH.round.value or 0) - (e.value or 0))
end

-- fast clicks (decision 281): the game wants one click per post and takes one post at a time. A click
-- while a post is still on its way is ignored (the button says "Wait..."), nothing is marked posted
-- before the game took it: the bags lose the item, or "AUCTION_HOUSE_AUCTION_CREATED" comes. Without
-- either within AH.POST_WAIT seconds the item comes back to the list. No price searches meanwhile.
AH.POST_WAIT = 4
local function itemCount(id)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, false) or 0 end
    if GetItemCount then return GetItemCount(id) or 0 end
    return 0
end
function AH.Busy()
    if posting and now() - posting.at < AH.POST_WAIT then return true end
    local B = OMQ.AuctionBuy
    return B and B.Busy and B.Busy() or false
end
-- the post went through: count it, the next click may come
local function postDone()
    if not posting then return end
    posting = nil
    if fastUI then fastUI.posted = (fastUI.posted or 0) + 1 end
    AH.Ready()
end
-- no sign from the game: did the bags lose it? else it comes back
local function postCheck()
    local p = posting
    if not p then return end
    if itemCount(p.itemID) < p.before then postDone()
    elseif now() - p.at >= AH.POST_WAIT then
        posting = nil
        for _, e in ipairs(entries) do if e.key == p.key then e.posted = nil end end
        p.entry.posted = nil
        uncount(p.entry)
        OMQ:Print("auction helper: " .. (p.entry.name or "the item") .. " was not posted - click again")
    end
end
AH._PostCheck = postCheck
local function startPosting(e)
    e.posted = true
    counted(e)
    posting = { entry = e, key = e.key, itemID = e.itemID, before = itemCount(e.itemID), at = now() }
    if C_Timer and C_Timer.After then
        C_Timer.After(AH.POST_WAIT + 0.1, function() postCheck(); AH.Refresh(); AH.Pump() end)
    end
end

local function stillThere(e)
    local C = C_Container
    local it = C and C.GetContainerItemInfo and C.GetContainerItemInfo(e.bag, e.slot)
    return it and it.itemID == e.itemID
end

function AH.Post(e, fromSelect)
    local A = CA()
    if not (A and e and e.state == "ok" and AH.open) then return false end
    AH.Quiet()
    postCheck()
    if AH.Busy() then AH.Refresh(); return false end         -- still on its way: this click is ignored (decision 281)
    if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then AH.WaitNote(); AH.Refresh(); return false end
    if pendingConfirm then                                     -- the second click confirms
        local c = pendingConfirm
        pendingConfirm = nil
        if c.entry.commodity then A.ConfirmPostCommodity(unpack(c.args)) else A.ConfirmPostItem(unpack(c.args)) end
        startPosting(c.entry)
        AH.Refresh()
        return true
    end
    if not stillThere(e) then AH.Scan(); AH.Refresh(); return false end
    local price = e.price
    if A.SupportsCopperValues and not A.SupportsCopperValues() then price = math.max(100, math.floor(price / 100) * 100) end
    local args, needs
    if e.commodity then
        args = { e.loc, AH.DURATION, e.qty, price }
        needs = A.PostCommodity(unpack(args))
    else
        args = { e.loc, AH.DURATION, 1, nil, price }
        needs = A.PostItem(e.loc, AH.DURATION, 1, nil, price)
    end
    if fromSelect then db().skip[e.itemID] = nil; db().fails[e.itemID] = nil end   -- posted in the select mode: a fresh start
    if e.name then db().names[e.name] = e.itemID end
    if needs then
        pendingConfirm = { entry = e, args = args }            -- the game warns about the price: click again
    else
        startPosting(e)
    end
    AH.Refresh()
    return true
end

function AH.Skip(e)
    if not e then return end
    db().skip[e.itemID] = true
    if pendingConfirm and pendingConfirm.entry == e then pendingConfirm = nil end
    AH.Evaluate()
    AH.Refresh()
end

function AH.PostNext()
    local L = AH.Lists()
    if pendingConfirm then return AH.Post(pendingConfirm.entry) end
    return AH.Post(L.fast[1], false)
end

----------------------------------------------------------------------
-- The panel next to the auction house
----------------------------------------------------------------------
local selUI, rows = nil, {}

local function qColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function fs(parent, font, r, g, b)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    t:SetJustifyH("LEFT")
    if r then t:SetTextColor(r, g, b) end
    return t
end

local function itemTip(owner, e)
    if not (GameTooltip and e) then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if GameTooltip.SetBagItem and e.bag then GameTooltip:SetBagItem(e.bag, e.slot)
    elseif e.link then GameTooltip:SetHyperlink(e.link) end
    GameTooltip:Show()
end

local function build()
    panel = CreateFrame("Frame", "OneMoreQuestAuctionHelper", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(380, 300)
    panel:SetFrameStrata("HIGH")
    panel:EnableMouse(true)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0.086, 0.094, 0.122, 0.97)
    local edge = panel:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT"); edge:SetHeight(2)
    edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    local tag = fs(panel, "GameFontNormalSmall", GOLD[1], GOLD[2], GOLD[3])
    tag:SetPoint("TOPLEFT", 16, -14); tag:SetText("AUCTION HELPER")
    panel.scan = fs(panel, "GameFontNormalSmall", 0.95, 0.62, 0.25)       -- a scan is running (decision 286)
    panel.scan:SetPoint("TOPRIGHT", -84, -14); panel.scan:SetText("Scanning - please wait..."); panel.scan:Hide()
    -- the cover while the whole house is read (decision 343)
    local veil = CreateFrame("Frame", nil, panel)
    veil:SetAllPoints()
    veil:SetFrameLevel(panel:GetFrameLevel() + 20)
    veil:EnableMouse(true)
    local vbg = veil:CreateTexture(nil, "BACKGROUND")
    vbg:SetAllPoints(); vbg:SetColorTexture(0.05, 0.055, 0.075, 0.97)
    veil.big = fs(veil, "GameFontNormalHuge", GOLD[1], GOLD[2], GOLD[3])
    veil.big:SetPoint("CENTER", 0, 10); veil.big:SetText("Scan running...")
    veil.sub = fs(veil, "GameFontNormalSmall", 0.75, 0.75, 0.8)
    veil.sub:SetPoint("TOP", veil.big, "BOTTOM", 0, -10); veil.sub:SetText("reading the whole auction house")
    veil:SetScript("OnUpdate", function(self)
        local pr = OMQ.Prices and OMQ.Prices.Progress and OMQ.Prices.Progress()
        if pr and (pr.total or 0) > 0 then self.sub:SetText(string.format("%d of %d auctions", pr.results or 0, pr.total))
        else self.sub:SetText("waiting for the auction house...") end
    end)
    veil:Hide()
    panel.veil = veil
    -- the small "Scan all" button and the header, which closes the helper on a right click (decision 290)
    local sa = CreateFrame("Button", nil, panel)
    sa:SetSize(64, 18); sa:SetPoint("TOPRIGHT", -12, -10)
    sa:SetFrameLevel(panel:GetFrameLevel() + 5)
    sa.bg = sa:CreateTexture(nil, "BACKGROUND"); sa.bg:SetAllPoints(); sa.bg:SetColorTexture(0.165, 0.141, 0.086, 1)
    sa.hl = sa:CreateTexture(nil, "HIGHLIGHT"); sa.hl:SetAllPoints(); sa.hl:SetColorTexture(1, 1, 1, 0.08)
    sa.text = sa:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); sa.text:SetPoint("CENTER"); sa.text:SetText("Scan all")
    sa.text:SetTextColor(0.95, 0.82, 0.48)
    sa:SetScript("OnClick", function() AH.ScanAll() end)
    sa:SetScript("OnEnter", function(self)
        if GameTooltip then GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetText("Scan everything again: bags, stock up, weapons, bags to buy"); GameTooltip:Show() end
    end)
    sa:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    panel.scanAll = sa
    local head = CreateFrame("Button", nil, panel)
    head:SetSize(200, 26); head:SetPoint("TOPLEFT", 0, 0)
    head:SetFrameLevel(panel:GetFrameLevel() + 5)
    head:RegisterForClicks("RightButtonUp")
    head:SetScript("OnClick", function(_, button) if button == "RightButton" then AH.Close() end end)
    head:SetScript("OnEnter", function(self)
        if GameTooltip then GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:SetText("Right click: close until the next visit"); GameTooltip:Show() end
    end)
    head:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    panel.head = head
    -- Sell | Buy as two big tabs over a framed box (decision 267); the box holds the way of selling or
    -- buying (Fast | Select, Fill up | Single) as a segmented switch, and everything below it
    local BOX = { 0.125, 0.135, 0.17 }
    local box = CreateFrame("Frame", nil, panel)
    box:SetPoint("TOPLEFT", 10, -64); box:SetPoint("BOTTOMRIGHT", -10, 10)
    box.bg = box:CreateTexture(nil, "BACKGROUND"); box.bg:SetAllPoints(); box.bg:SetColorTexture(BOX[1], BOX[2], BOX[3], 1)
    local function line(p1, p2, w, h)
        local t = box:CreateTexture(nil, "BORDER")
        t:SetPoint(p1); t:SetPoint(p2)
        if w then t:SetWidth(w) else t:SetHeight(h) end
        t:SetColorTexture(0.45, 0.37, 0.18, 1)
        return t
    end
    line("TOPLEFT", "TOPRIGHT", nil, 1); line("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    line("TOPLEFT", "BOTTOMLEFT", 1); line("TOPRIGHT", "BOTTOMRIGHT", 1)
    panel.box = box
    local function tab(label, view, x)
        local t = CreateFrame("Button", nil, panel)
        t:SetSize(180, 35)                                   -- 1 px over the box: the open tab merges with it
        t:SetPoint("TOPLEFT", x, -30)
        t:SetFrameLevel(box:GetFrameLevel() + 2)
        t.bg = t:CreateTexture(nil, "BACKGROUND"); t.bg:SetAllPoints()
        t.top = t:CreateTexture(nil, "BORDER"); t.top:SetPoint("TOPLEFT"); t.top:SetPoint("TOPRIGHT"); t.top:SetHeight(3)
        t.top:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        t.text = t:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); t.text:SetPoint("CENTER", 0, 1); t.text:SetText(label)
        t.hl = t:CreateTexture(nil, "HIGHLIGHT"); t.hl:SetAllPoints(); t.hl:SetColorTexture(1, 1, 1, 0.05)
        t:SetScript("OnClick", function() AH.SetView(view) end)
        t.view = view
        return t
    end
    panel.sellBtn = tab("Sell", "sell", 10)
    panel.buyBtn = tab("Buy", "buy", 190)
    panel.sellBtn.mode, panel.buyBtn.mode = "sell", "buy"
    panel.BOX = BOX
    local function segment(label, mode, x, onClick)
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(100, 26)
        b:SetPoint("TOPLEFT", x, -76)
        b:SetFrameLevel(box:GetFrameLevel() + 2)
        b.edge = b:CreateTexture(nil, "BACKGROUND"); b.edge:SetPoint("TOPLEFT", -1, 1); b.edge:SetPoint("BOTTOMRIGHT", 1, -1)
        b.edge:SetColorTexture(0.45, 0.37, 0.18, 1)
        b.bg = b:CreateTexture(nil, "BORDER"); b.bg:SetAllPoints()
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal"); b.text:SetPoint("CENTER"); b.text:SetText(label)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 1, 1, 0.06)
        b:SetScript("OnClick", onClick)
        b.mode = mode
        return b
    end
    panel.fastBtn = segment("Fast", "fast", 22, function() AH.SetMode("fast") end)
    panel.selBtn = segment("Select", "select", 123, function() AH.SetMode("select") end)
    panel.fillBtn = segment("Fill up", "fill", 22, function() OMQ.AuctionBuy.SetMode("fill") end)
    panel.oneBtn = segment("Single", "single", 123, function() OMQ.AuctionBuy.SetMode("single") end)
    panel.modeHint = fs(box, "GameFontHighlightSmall", 0.72, 0.74, 0.79)
    panel.modeHint:SetPoint("LEFT", panel.selBtn, "RIGHT", 12, 0); panel.modeHint:SetWidth(130)

    -- fast mode
    fastUI = CreateFrame("Frame", nil, panel)
    fastUI:SetPoint("TOPLEFT", 0, -AH.HEAD); fastUI:SetPoint("BOTTOMRIGHT")
    fastUI:SetFrameLevel(box:GetFrameLevel() + 2)
    fastUI.lead = fs(fastUI, "GameFontHighlight", 0.79, 0.8, 0.84); fastUI.lead:SetPoint("TOPLEFT", 16, -4)
    fastUI.profit = fs(fastUI, "GameFontNormalHuge", 0.95, 0.82, 0.48); fastUI.profit:SetPoint("TOPLEFT", 16, -22)
    fastUI.clicks = fs(fastUI, "GameFontHighlight"); fastUI.clicks:SetPoint("TOPLEFT", 16, -56)
    fastUI.barBg = fastUI:CreateTexture(nil, "ARTWORK"); fastUI.barBg:SetPoint("TOPLEFT", 16, -78)
    fastUI.barBg:SetSize(348, 5); fastUI.barBg:SetColorTexture(0.23, 0.2, 0.14, 1)
    fastUI.bar = fastUI:CreateTexture(nil, "OVERLAY"); fastUI.bar:SetPoint("TOPLEFT", fastUI.barBg, "TOPLEFT")
    fastUI.bar:SetSize(1, 5); fastUI.bar:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    local post = CreateFrame("Button", "OneMoreQuestAuctionPost", fastUI)
    post:SetSize(348, 58); post:SetPoint("TOPLEFT", 16, -92)
    post:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    post.bg = post:CreateTexture(nil, "BACKGROUND"); post.bg:SetAllPoints(); post.bg:SetColorTexture(0.165, 0.141, 0.086, 1)
    post.edge = post:CreateTexture(nil, "BORDER"); post.edge:SetPoint("TOPLEFT", -1, 1); post.edge:SetPoint("BOTTOMRIGHT", 1, -1)
    post.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.9)
    post.bg:SetDrawLayer("BACKGROUND", 1); post.edge:SetDrawLayer("BACKGROUND", 0)
    post.flash = post:CreateTexture(nil, "ARTWORK"); post.flash:SetAllPoints(); post.flash:SetColorTexture(0.25, 0.85, 0.35, 0.3); post.flash:Hide()
    post.icon = post:CreateTexture(nil, "ARTWORK"); post.icon:SetSize(38, 38); post.icon:SetPoint("LEFT", 10, 0)
    post.count = fs(post, "NumberFontNormal"); post.count:SetPoint("BOTTOMRIGHT", post.icon, "BOTTOMRIGHT", -1, 1)
    post.title = fs(post, "GameFontNormalLarge", 0.95, 0.82, 0.48); post.title:SetPoint("TOPLEFT", post.icon, "TOPRIGHT", 10, -1)
    post.name = fs(post, "GameFontHighlightSmall"); post.name:SetPoint("BOTTOMLEFT", post.icon, "BOTTOMRIGHT", 10, 2)
    post.name:SetWidth(210); if post.name.SetWordWrap then post.name:SetWordWrap(false) end
    -- right side: the price of one piece and of the whole stack (decision 268)
    post.gain = fs(post, "GameFontHighlightSmall", 0.79, 0.8, 0.84); post.gain:SetPoint("TOPRIGHT", -10, -12); post.gain:SetJustifyH("RIGHT")
    post.stack = fs(post, "GameFontNormal", 0.95, 0.82, 0.48); post.stack:SetPoint("BOTTOMRIGHT", -10, 11); post.stack:SetJustifyH("RIGHT")
    post:SetScript("OnClick", function(_, button)
        if button == "RightButton" then AH.Skip(AH.Lists().fast[1]) else AH.PostNext() end
    end)
    post:SetScript("OnEnter", function(self) itemTip(self, AH.Lists().fast[1]) end)
    post:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    fastUI.post = post
    fastUI.hint = fs(fastUI, "GameFontDisableSmall"); fastUI.hint:SetPoint("TOPLEFT", 16, -158); fastUI.hint:SetWidth(348)
    fastUI.hint:SetText("Left click: post (24 hours, current price) - right click: skip")
    fastUI.total = fs(fastUI, "GameFontHighlightSmall", 0.79, 0.8, 0.84); fastUI.total:SetWidth(348)
    fastUI.done = fs(fastUI, "GameFontNormalLarge", 0.95, 0.82, 0.48); fastUI.done:SetPoint("TOPLEFT", 16, -8); fastUI.done:SetWidth(348)

    -- select mode
    selUI = CreateFrame("Frame", nil, panel)
    selUI:SetPoint("TOPLEFT", 0, -AH.HEAD); selUI:SetPoint("BOTTOMRIGHT")
    selUI:SetFrameLevel(box:GetFrameLevel() + 2)
    selUI.head = fs(selUI, "GameFontHighlight", 0.79, 0.8, 0.84); selUI.head:SetPoint("TOPLEFT", 16, -4)
    selUI.offset = 0
    selUI:EnableMouseWheel(true)
    selUI:SetScript("OnMouseWheel", function(_, d)
        local n = #AH.Lists().select
        selUI.offset = math.max(0, math.min(math.max(0, n - AH.ROWS), selUI.offset - d))
        AH.Refresh()
    end)
    for i = 1, AH.ROWS do
        local r = CreateFrame("Button", nil, selUI)
        r:SetSize(348, 40); r:SetPoint("TOPLEFT", 16, -24 - (i - 1) * 42)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(32, 32); r.icon:SetPoint("LEFT", 4, 0)
        r.count = fs(r, "NumberFontNormalSmall"); r.count:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", -1, 1)
        r.name = fs(r, "GameFontHighlight"); r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -1); r.name:SetWidth(220)
        if r.name.SetWordWrap then r.name:SetWordWrap(false) end
        r.prices = fs(r, "GameFontDisableSmall"); r.prices:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 8, 1)
        r.prices:SetWidth(240); if r.prices.SetWordWrap then r.prices:SetWordWrap(false) end
        r.right = fs(r, "GameFontNormal"); r.right:SetPoint("RIGHT", -6, 0); r.right:SetJustifyH("RIGHT")
        r:SetScript("OnClick", function(self, button)
            if not self.entry then return end
            if button == "RightButton" then AH.Skip(self.entry) else AH.Post(self.entry, true) end
        end)
        r:SetScript("OnEnter", function(self) itemTip(self, self.entry) end)
        r:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        rows[i] = r
    end
    selUI.foot = fs(selUI, "GameFontDisableSmall"); selUI.foot:SetWidth(348)

    -- the bottom line of both modes: what stays in the bags
    panel.out = fs(box, "GameFontDisableSmall"); panel.out:SetWidth(348)
    panel:Hide()
end
AH._Panel = function() return panel end
AH._Rows = function() return rows end
AH._Fast = function() return fastUI end

local function outText(L)
    if #L.out == 0 then return "" end
    local names = {}
    for i = 1, math.min(3, #L.out) do
        local e = L.out[i]
        local why = ({ low = "under +5%", noprice = "no price yet", upgrade = "upgrade for you", needed = "a dad needs it" })[e.state] or e.state
        names[#names + 1] = e.name .. " (" .. why .. ")"
    end
    local more = #L.out > 3 and (" and " .. (#L.out - 3) .. " more") or ""
    return #L.out .. (#L.out == 1 and " item stays" or " items stay") .. " in your bags: " .. table.concat(names, ", ") .. more
end

-- the open tab has the colour of the box and gold letters; the other one is dark with light grey letters
local function paintTab(t, on)
    local B = panel.BOX
    if on then t.bg:SetColorTexture(B[1], B[2], B[3], 1) else t.bg:SetColorTexture(0.055, 0.06, 0.078, 1) end
    t.top:SetShown(on)
    if on then t.text:SetTextColor(0.98, 0.84, 0.45) else t.text:SetTextColor(0.68, 0.7, 0.75) end
end
-- the chosen segment: gold with black letters; the other one: dark grey with white letters
local function paint(b, on)
    if on then b.bg:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1) else b.bg:SetColorTexture(0.2, 0.21, 0.25, 1) end
    if on then b.text:SetTextColor(0.07, 0.07, 0.08) else b.text:SetTextColor(0.93, 0.93, 0.95) end
end
AH.MODE_HINT = { fast = "one button, item after item", select = "pick item by item",
                 fill = "a click fills up to the target", single = "a click buys one piece" }

function AH.SetView(v, auto)
    AH.view = (v == "buy") and "buy" or "sell"
    if not auto then AH.manualView = true end
    AH.Refresh()
    AH.Pump()
end

function AH.Refresh()
    if not panel or not panel:IsShown() then return end
    paintScan()
    local L = AH.Lists()
    -- nothing (more) to sell: on to buying, unless the dad chose the view himself (decision 264)
    if AH.view == "sell" and not AH.manualView and L.pending == 0 and #L.fast == 0 and not pendingConfirm
        and (AH.Mode() == "fast" or #L.select == 0) then
        AH.view = "buy"
        AH.Pump()                                   -- the buy tab is looked at now: its prices are asked
    end
    local buy = AH.view == "buy"
    paintTab(panel.sellBtn, not buy); paintTab(panel.buyBtn, buy)
    for _, b in ipairs({ panel.fastBtn, panel.selBtn }) do b:SetShown(not buy) end
    for _, b in ipairs({ panel.fillBtn, panel.oneBtn }) do b:SetShown(buy) end
    if buy then
        local bm = OMQ.AuctionBuy.Mode()
        paint(panel.fillBtn, bm == "fill"); paint(panel.oneBtn, bm == "single")
        panel.modeHint:SetText(AH.MODE_HINT[bm] or "")
        fastUI:Hide(); selUI:Hide(); panel.out:SetText("")
        local h = OMQ.AuctionBuy.Render(panel, AH.HEAD)
        panel:SetHeight(AH.HEAD + h + 16)
        return
    end
    if OMQ.AuctionBuy then OMQ.AuctionBuy.Hide() end
    local mode = AH.Mode()
    for _, b in ipairs({ panel.fastBtn, panel.selBtn }) do paint(b, b.mode == mode) end
    panel.modeHint:SetText(AH.MODE_HINT[mode] or "")
    fastUI:SetShown(mode == "fast")
    selUI:SetShown(mode == "select")
    local h
    if mode == "fast" then
        local f = fastUI
        local next_ = pendingConfirm and pendingConfirm.entry or L.fast[1]
        local working = next_ ~= nil
        for _, w in ipairs({ f.lead, f.profit, f.clicks, f.barBg, f.bar, f.post, f.hint }) do w:SetShown(working) end
        f.total:SetText("")                                  -- the total is on top now (decision 268)
        f.done:SetShown(not working)
        if working then
            f.lead:SetText(string.format("Total value for all %d auction%s", L.roundCount, L.roundCount == 1 and "" or "s"))
            f.profit:SetText(money(L.roundValue))
            f.clicks:SetText(string.format("|cfff2d27a%d click%s|r and you are done", #L.fast, #L.fast == 1 and "" or "s"))
            f.posted = f.posted or 0
            local all = #L.fast + (f.posted or 0)
            f.bar:SetWidth(math.max(1, 348 * (f.posted or 0) / math.max(1, all)))
            f.post.icon:SetTexture(next_.icon)
            f.post.count:SetText((next_.qty or 1) > 1 and next_.qty or "")
            local busy = AH.Busy()
            f.post.flash:SetShown(not busy and AH.Flashing())
            f.post.title:SetText((busy and "Wait...") or (pendingConfirm and "Confirm post - price warning")
                or string.format("Post (%d/%d)", (f.posted or 0) + 1, all))
            f.post.name:SetText(next_.name); f.post.name:SetTextColor(qColor(next_.quality))
            local unit = next_.price or 0
            local qty = next_.commodity and (next_.qty or 1) or 1
            f.post.gain:SetText(qty > 1 and (money(unit) .. " each") or "")
            f.post.stack:SetText(money(unit * qty))
            h = AH.HEAD + 176
            f.total:ClearAllPoints(); f.total:SetPoint("TOPLEFT", 16, -176)
        else
            local text
            if L.pending > 0 then text = string.format("Checking prices... %d of %d", L.count - L.pending, L.count)
            elseif (f.posted or 0) > 0 then text = "All posted!|n|cffe5e3dc" .. f.posted .. " auctions for 24 hours.|r"
            else text = "Nothing to post today|n|cffc9ccd5Nothing in your bags brings at least 5% more here than at the vendor.|r" end
            local skipped = 0
            for _, e in ipairs(L.select) do if e.skipped then skipped = skipped + 1 end end
            if skipped > 0 and L.pending == 0 then text = text .. "|n|cff9aa0aa" .. skipped .. " skipped - in the select mode.|r" end
            f.done:SetText(text)
            h = AH.HEAD + 30 + (tonumber((f.done:GetStringHeight())) or 40)
            f.total:ClearAllPoints(); f.total:SetPoint("TOPLEFT", 16, -(h - AH.HEAD + 2))
            h = h + 20
        end
    else
        local list = L.select
        selUI.offset = math.min(selUI.offset, math.max(0, #list - AH.ROWS))
        local open = 0
        for _, e in ipairs(list) do if not e.skipped then open = open + 1 end end
        selUI.head:SetText(L.pending > 0 and string.format("Checking prices... %d of %d", L.count - L.pending, L.count)
            or string.format("%d to post - left click: post, right click: skip", open))
        local shown = 0
        for i, r in ipairs(rows) do
            local e = list[i + selUI.offset]
            r.entry = e
            r:SetShown(e ~= nil)
            if e then
                shown = i
                local first = (pendingConfirm and pendingConfirm.entry == e) or (not pendingConfirm and i + selUI.offset == 1 and not e.skipped)
                if e.useful then                                 -- my own consumable: a blue row (decision 282)
                    r.bg:SetColorTexture(0.07, 0.15, 0.22, e.skipped and 0.6 or 1)
                else
                    r.bg:SetColorTexture(first and 0.165 or 0.11, first and 0.141 or 0.122, first and 0.086 or 0.153, e.skipped and 0.6 or 1)
                end
                r.icon:SetTexture(e.icon); r.icon:SetDesaturated(e.skipped and true or false)
                r.count:SetText((e.qty or 1) > 1 and e.qty or "")
                r.name:SetText(e.name); r.name:SetTextColor(qColor(e.quality))
                -- what the buyer pays: one piece and the whole auction (decision 270)
                local qty = e.commodity and (e.qty or 1) or 1
                local each = qty > 1 and (money(e.price or 0) .. " each") or ""
                -- a consumable I use: which of the two ways this row is (decision 274)
                if e.keep then each = "|cff7fc8ffyour consumable|r - |cff9fdc8akeep " .. e.keep .. "|r" .. (each ~= "" and (" - " .. each) or "")
                elseif e.useful then each = "|cff7fc8ffyour consumable|r - |cffff9a6asell all|r" .. (each ~= "" and (" - " .. each) or "") end
                r.prices:SetText(each)
                if pendingConfirm and pendingConfirm.entry == e then r.right:SetText("Click: confirm"); r.right:SetTextColor(0.95, 0.82, 0.48)
                elseif e.skipped then r.right:SetText(db().skip[e.itemID] == "unsold" and "Unsold twice" or "Skipped"); r.right:SetTextColor(0.54, 0.56, 0.61)
                else r.right:SetText(money((e.price or 0) * (e.commodity and (e.qty or 1) or 1))); r.right:SetTextColor(0.95, 0.82, 0.48) end
            end
        end
        selUI.foot:ClearAllPoints()
        selUI.foot:SetPoint("TOPLEFT", 16, -28 - shown * 42)
        local more = #list > AH.ROWS and string.format("Mouse wheel: %d more", #list - AH.ROWS) or ""
        selUI.foot:SetText(more)
        h = AH.HEAD + 34 + shown * 42 + (more ~= "" and 16 or 0)
    end
    local out = outText(L)
    panel.out:ClearAllPoints()
    panel.out:SetPoint("TOPLEFT", 16, -(h + 4))
    panel.out:SetText(out)
    local oh = out ~= "" and ((panel.out:GetStringHeight() or 24) + 12) or 0
    panel:SetHeight(h + oh + 20)
end

----------------------------------------------------------------------
-- Unsold twice in a row: off the fast list (decision 261)
-- The game mails every result: "Auction expired: <item>" (it comes back) or "Auction successful:
-- <item>". Each mail counts once; a sale starts the count again. At 2 the item is skipped like a
-- right click ("Unsold twice" in the select mode), until it is posted there again.
----------------------------------------------------------------------
AH.UNSOLD_LIMIT = 2
local function subjectPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%%d%%%$s", "(.+)"):gsub("%%%%s", "(.+)")
    return "^" .. p .. "$"
end
function AH.Earned()
    local d = db()
    d.earned = d.earned or {}
    local guid = UnitGUID and UnitGUID("player") or "?"
    d.earned[guid] = d.earned[guid] or { copper = 0, sales = 0 }
    return d.earned[guid]
end
function AH.EarnedText()
    local e = AH.Earned()
    if e.sales == 0 then return "Total won so far: nothing sold yet" end
    return string.format("Total won so far: |cfff2d27a%s|r from %d sale%s", money(e.copper), e.sales, e.sales == 1 and "" or "s")
end

function AH.Result(itemID, sold)
    if not itemID then return end
    local d = db()
    if sold then d.fails[itemID] = nil; return end
    d.fails[itemID] = (d.fails[itemID] or 0) + 1
    if d.fails[itemID] >= AH.UNSOLD_LIMIT and not d.skip[itemID] then d.skip[itemID] = "unsold" end
end
function AH.ScanMail()
    if not (GetInboxNumItems and GetInboxHeaderInfo) then return end
    local d = db()
    local expired = subjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT or "Auction expired: %s")
    local soldP = subjectPattern(AUCTION_SOLD_MAIL_SUBJECT or "Auction successful: %s")
    local t = time()
    for k, at in pairs(d.mails) do if t - at > 35 * 86400 then d.mails[k] = nil end end
    for i = 1, GetInboxNumItems() or 0 do
        local _, _, _, subject, money_, _, daysLeft = GetInboxHeaderInfo(i)
        if type(subject) == "string" and not isSecret(subject) then
            local name, sold = expired and subject:match(expired), false
            if not name and soldP then name = subject:match(soldP); sold = name ~= nil end
            if name then
                local key = subject .. "@" .. math.floor((t + (daysLeft or 0) * 86400) / 3600)
                if not d.mails[key] then
                    d.mails[key] = t
                    local id = d.names[name]
                    if not id and not sold and GetInboxItem then id = select(2, GetInboxItem(i, 1)) end
                    if type(id) == "number" then AH.Result(id, sold) end
                    -- what the helper's auctions brought in, per character (decision 262)
                    if sold and id and type(money_) == "number" and not isSecret(money_) and money_ > 0 then
                        local e = AH.Earned()
                        e.copper, e.sales = e.copper + money_, e.sales + 1
                    end
                end
            end
        end
    end
end
local mailEv = CreateFrame("Frame")
pcall(mailEv.RegisterEvent, mailEv, "MAIL_INBOX_UPDATE")
mailEv:SetScript("OnEvent", function() local ok, err = pcall(AH.ScanMail); if not ok then OMQ:Error("auction mails", err) end end)

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local function anchor()
    panel:ClearAllPoints()
    local ahf = _G.AuctionHouseFrame
    if ahf then panel:SetPoint("TOPLEFT", ahf, "TOPRIGHT", 6, 0) else panel:SetPoint("LEFT", UIParent, "CENTER", 200, 0) end
end

function AH.Open()
    if not AH.Enabled() then return end
    if not panel then build() end
    AH.open = true
    pendingConfirm, asking, posting = nil, nil, nil
    for k in pairs(tried) do tried[k] = nil end
    AH.quietUntil, AH.readyAt = nil, nil
    fastUI.posted = 0
    AH.round = { n = 0, income = 0 }
    AH.view, AH.manualView = "sell", false            -- always sell first (decision 264)
    if OMQ.AuctionBuy then OMQ.AuctionBuy.Open() end
    anchor()
    panel:Show()
    -- the scan of the whole house comes first; the cover goes up until the dump is read (decision 343)
    local PR = OMQ.Prices
    if PR and PR.Start then
        if not PR.AutoOn() or PR.Busy() then
        else
            local at = PR.ScannedAt()
            local age = at and ((time and time() or 0) - at)
            if age and age <= PR.MAX_AGE then
                -- the last scan is still fresh: no new one
            else
                PR.Start(false)
            end
        end
    end
    AH.Scan()
    AH.Refresh()
    AH.Pump()
    paintScan()
end

function AH.Close()
    AH.open = false
    pendingConfirm, asking = nil, nil
    if panel then panel:Hide() end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
                     "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_WARNING",
                     "AUCTION_HOUSE_POST_ERROR", "BAG_UPDATE_DELAYED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
                     "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1)
    local ok, err = pcall(function()
        if event == "AUCTION_HOUSE_SHOW" then AH.Open()
        elseif event == "AUCTION_HOUSE_CLOSED" then AH.Close()
        elseif not AH.open then return
        elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
            if asking and not asking.browse and asking.commodity ~= false and asking.itemID == a1 then
                asking.commodity = true; gotPrice(asking)
            end
        elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
            if asking and not asking.browse and asking.commodity ~= true and (keyString(a1) == keyString(asking.itemKey)
                or (asking.anyKey and type(a1) == "table" and a1.itemID == asking.itemID)) then
                asking.commodity = false
                if asking.anyKey and type(a1) == "table" then asking.itemKey = a1 end   -- the key the game really uses (decision 343)
                gotPrice(asking)
            end
        elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
            if asking and asking.browse then
                asking.answered = true
                -- decisions 326 and 331: the game can answer a browse or a batch first with an empty list and fill
                -- it a moment later; an empty answer waits for the next one (or the timeout)
                local A = CA()
                local n = #(A.GetBrowseResults and A.GetBrowseResults() or {})
                asking.answers = asking.answers or {}
                asking.answers[#asking.answers + 1] = string.format("%s %d%s after %.1fs", event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" and "added" or "updated",
                    n, (A.HasFullBrowseResults and not A.HasFullBrowseResults()) and " (not full)" or "", now() - askedAt)
                if n > 0 then gotPrice(asking) end
            end
        elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then AH.Pump()
        elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
            postDone()
            AH.Refresh()
            AH.Pump()
        elseif event == "AUCTION_HOUSE_POST_ERROR" then
            if posting then
                local p = posting
                posting = nil
                for _, e in ipairs(entries) do if e.key == p.key then e.posted = nil end end
                p.entry.posted = nil
                uncount(p.entry)
            end
            AH.Refresh()
        elseif event == "AUCTION_HOUSE_POST_WARNING" then AH.Refresh()
        elseif event == "BAG_UPDATE_DELAYED" then
            -- keep what is known: the posted flags go with the bag contents
            local keep = {}
            for _, e in ipairs(entries) do if e.posted then keep[e.key] = true end end
            AH.Scan()
            for _, e in ipairs(entries) do if keep[e.key] then e.posted = true end end
            postCheck()                                  -- the bags lost it: the post went through
            AH.Refresh()
            AH.Pump()
        end
    end)
    if not ok then OMQ:Error("auction helper", err) end
end)
-- a slow tick: the throttle and a search without an answer
local tick = CreateFrame("Frame")
local acc = 0
tick:SetScript("OnUpdate", function(_, el)
    if not AH.open then return end
    acc = acc + (el or 0)
    if acc < 0.5 then return end
    acc = 0
    pcall(AH.Pump)
end)
OMQ:On("NEEDS_ANSWER", function() if AH.open then AH.Scan(); AH.Refresh() end end)

OMQ:RegisterCommand("ah", function(arg)
    arg = (arg or ""):lower()
    if arg == "fast" or arg == "select" then AH.SetMode(arg); OMQ:Print("auction helper: " .. arg .. " mode"); return end
    if arg == "unskip" then db().skip = {}; OMQ:Print("auction helper: no item is skipped any more"); AH.Evaluate(); AH.Refresh(); return end
    if arg == "bags" then                                -- what the bag search saw (decision 320)
        local B = OMQ.AuctionBuy
        for _, l in ipairs(B and B.BagReport and B.BagReport() or { "bags: no buy mode" }) do OMQ:Print(l) end
        return
    end
    local n = 0
    for _ in pairs(db().skip) do n = n + 1 end
    OMQ:Print("auction helper: " .. AH.Mode() .. " mode, " .. n .. " skipped items. " .. AH.EarnedText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. ".  /omq ah fast | select | unskip | bags")
end, "auction helper: fast or select mode, forget the skipped items")
