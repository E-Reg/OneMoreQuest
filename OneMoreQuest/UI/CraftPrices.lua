-- One More Quest: auction house prices of everything (decision 341, step 1 of the crafting profit)
-- The whole auction house is read once with C_AuctionHouse.ReplicateItems (a dump of all auctions, decision 342), and the
-- lowest price of every item is kept in the saved variables (per realm) until the next scan replaces it.
-- The crafting profit (UI/CraftProfit.lua) reads these prices. The scan starts by itself when the auction
-- house opens and the last one is older than an hour (option), or with
-- /omq prices scan. It gives way to the auction helper: it never starts while the helper asks for something,
-- and it waits while a post or a purchase is going on.
-- Vendor prices are learned too: every merchant window written down what an item costs there, so reagents
-- from a vendor (thread, vials) count in the profit with their vendor price.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local P = {}
OMQ.Prices = P

P.MAX_AGE = 900             -- an automatic scan only when the last one is older: the server lets a dump be asked for about every 15 minutes (decision 343)
P.START_DELAY = 0.2         -- seconds after the window opens before the scan starts (decision 343)

local function now() return GetTime() end
local function isSecret(v) return issecretvalue and issecretvalue(v) end
local function stamp() return time and time() or 0 end

local function realm() return (GetRealmName and GetRealmName()) or "?" end
local function store()
    OMQDB.prices = OMQDB.prices or {}
    local r = realm()
    OMQDB.prices[r] = OMQDB.prices[r] or { items = {}, at = 0, n = 0 }
    return OMQDB.prices[r]
end
local function vendorStore()
    OMQDB.vendorPrices = OMQDB.vendorPrices or {}
    return OMQDB.vendorPrices
end

function P.AutoOn() return not (OMQ.db and OMQ.db.options and OMQ.db.options.priceScan == false) end

-- the lowest auction price of one piece (copper), its quantity on offer, and the time of the scan
function P.Auction(itemID)
    local e = store().items[itemID]
    if e then return e.p, e.q, store().at end
end
function P.Vendor(itemID) return vendorStore()[itemID] end
-- what the item costs me to get: the cheaper of the auction house and a vendor; nil = unknown
function P.Cost(itemID)
    local a, v = P.Auction(itemID), P.Vendor(itemID)
    if a and v then return math.min(a, v), a <= v and "ah" or "vendor" end
    if a then return a, "ah" end
    if v then return v, "vendor" end
    return nil
end
function P.ScannedAt() local at = store().at; return at and at > 0 and at or nil end
function P.Count() return store().n or 0 end

----------------------------------------------------------------------
-- The scan: C_AuctionHouse.ReplicateItems gives a dump of the whole auction house (decision 342)
----------------------------------------------------------------------
local scan = nil           -- { state "start" | "requested" | "reading", n, i, seen, results, startedAt }
function P.Busy() return scan ~= nil end
-- the dump is good for this window: a scan finished, or the last one is fresh (decision 343)
local sessionAt = nil
function P.Session() return sessionAt ~= nil and not scan end
function P.SessionAt() return sessionAt end
function P.EndSession() sessionAt = nil end
function P.Items() return store().items end
function P.Progress() return scan and { results = scan.results, total = scan.n } or nil end
P.last = nil               -- how the last scan ended: { ok, items, secs, results, why }
P.CHUNK = 400              -- auctions read per step, so a dump of many thousands does not freeze the game
P.WAIT = 30                -- seconds to wait for the dump

local function helper() return OMQ.AuctionHelper end
local function A() return C_AuctionHouse end

local function finish(ok, why)
    if not scan then return end
    local st = store()
    local n = 0
    for _ in pairs(scan.seen) do n = n + 1 end
    if ok then
        st.items = scan.items                 -- the dump replaces the list: what was sold is gone
        st.at, st.n = stamp(), n
        sessionAt = now()
    end
    P.last = { ok = ok, items = n, secs = now() - scan.startedAt, results = scan.results, why = why }
    scan = nil
    local H = helper()
    if ok and H and H.Evaluate then pcall(H.Evaluate) end
    if H and H.Refresh then pcall(H.Refresh) end
    if H and H.Pump then pcall(H.Pump) end
    if OMQ.Fire then OMQ:Fire("PRICES_UPDATED", ok) end
end

-- one auction of the dump: the lowest buyout per piece of every item, and the pieces on offer
local function take(i)
    local api = A()
    local ok, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = pcall(api.GetReplicateItemInfo, i)
    if not ok then return end
    if isSecret(itemID) or isSecret(buyout) or isSecret(count) then return end
    count = tonumber(count) or 1
    if count < 1 then count = 1 end
    if not (itemID and type(buyout) == "number" and buyout > 0) then return end   -- bid only: no price to count on
    local unit = math.max(1, math.floor(buyout / count))
    local e = scan.items[itemID]
    if e then
        if unit < e.p then e.p = unit end
        e.q = e.q + count
    else
        scan.items[itemID] = { p = unit, q = count }
        scan.seen[itemID] = true
    end
end

local function throttleReady()
    local api = A()
    return not (api and api.IsThrottledMessageSystemReady) or api.IsThrottledMessageSystemReady()
end

local function yielding()
    local H = helper()
    if not H then return false end
    if H.Busy and H.Busy() then return true end
    if H.quietUntil and now() < H.quietUntil then return true end
    return false
end

local function beginReading()
    local api = A()
    scan.n = api.GetNumReplicateItems and tonumber(api.GetNumReplicateItems()) or 0
    scan.i, scan.state = 0, "reading"
end

-- the next step: send the request, wait for the dump, or read the next chunk of it
function P.Step()
    if not scan then return end
    local api = A()
    local H = helper()
    if not (api and H and H.open) then finish(false, "the window closed"); return end
    if scan.state == "start" then
        if yielding() or not throttleReady() then return end
        scan.state, scan.requestedAt = "requested", now()
        local ok, err = pcall(api.ReplicateItems)
        if not ok then finish(false, "ReplicateItems failed: " .. tostring(err)) end
    elseif scan.state == "requested" then
        if now() - scan.requestedAt > P.WAIT then
            -- the dump may be there without an event (asked for a short while ago)
            beginReading()
            if scan.n == 0 then finish(false, "the game sent no dump") end
        end
    elseif scan.state == "reading" then
        local last = math.min(scan.n, scan.i + P.CHUNK)
        for i = scan.i + 1, last do take(i); scan.results = scan.results + 1 end
        scan.i = last
        if scan.i >= scan.n then finish(true) end
    end
end

function P.Start(manual)
    if scan then return false, "a scan is running" end
    local H = helper()
    if not (H and H.open) then return false, "open the auction house first" end
    local api = A()
    if not (api and api.ReplicateItems and api.GetNumReplicateItems and api.GetReplicateItemInfo) then
        return false, "this client has no ReplicateItems"
    end
    scan = { state = "start", items = {}, seen = {}, results = 0, n = 0, i = 0, startedAt = now() }
    if manual then OMQ:Print("prices: asking the auction house for everything - the game answers in a moment") end
    sessionAt = nil
    if H.Refresh then pcall(H.Refresh) end
    P.Step()
    return true
end

function P.Cancel() if scan then finish(false, "stopped") end end

----------------------------------------------------------------------
-- Events and commands
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE", "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end

-- what a merchant sells and for how much one piece (decisions 341, 345). The client may have the old globals or
-- C_MerchantFrame; both are tried, and the result is told once per merchant window.
local function merchantItem(i)
    local link, price, qty, extended
    local M = C_MerchantFrame
    if M and M.GetItemInfo then
        local ok, t = pcall(M.GetItemInfo, i)
        if ok and type(t) == "table" then price, qty, extended = t.price, t.stackCount, t.hasExtendedCost end
    end
    if price == nil and GetMerchantItemInfo then
        local ok, _, _, p, q, _, _, x = pcall(GetMerchantItemInfo, i)
        if ok then price, qty, extended = p, q, x end
    end
    if GetMerchantItemLink then link = GetMerchantItemLink(i)
    elseif M and M.GetItemLink then link = M.GetItemLink(i) end
    return link, price, qty, extended
end
function P.LearnVendor()
    local num = GetMerchantNumItems and GetMerchantNumItems() or (C_MerchantFrame and C_MerchantFrame.GetNumItems and C_MerchantFrame.GetNumItems()) or 0
    local n, vs = 0, vendorStore()
    for i = 1, num do
        local link, price, qty, extended = merchantItem(i)
        local id = link and tonumber(tostring(link):match("item:(%d+)"))
        if id and type(price) == "number" and not isSecret(price) and price > 0 and not extended then
            vs[id] = math.floor(price / math.max(1, tonumber(qty) or 1))
            n = n + 1
        end
    end
    P.lastMerchant = { items = num, learned = n }
    return n
end

-- the latest scanned price in every item tooltip (decision 345): the cheaper of auction house and vendor
local function agoText(at)
    if not at then return "" end
    local d = (time and time() or 0) - at
    if d < 120 then return "just now" end
    if d < 7200 then return math.floor(d / 60) .. " min ago" end
    if d < 172800 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " days ago"
end
local function money(c)
    local C = OMQ.CraftProfit
    if C and C.Money then return C.Money(c) end
    return c .. "c"
end
function P.TooltipLines(id)
    local a, q, at = P.Auction(id)
    local v = P.Vendor(id)
    if not a and not v then return nil end
    local best, src = P.Cost(id)
    local lines = { { "Price: " .. money(best) .. (src == "vendor" and "  (vendor)" or "  (auction house)"), 0.85, 0.75, 0.4 } }
    if a and v then
        lines[#lines + 1] = { string.format("Auction house %s - vendor %s", money(a), money(v)), 0.6, 0.6, 0.6 }
    end
    if a then
        lines[#lines + 1] = { string.format("scanned %s%s", agoText(at), q and (", " .. q .. " on offer") or ""), 0.5, 0.5, 0.5 }
    end
    return lines
end
local function onTip(tt, data)
    if not tt or (tt.IsForbidden and tt:IsForbidden()) then return end
    local id = data and data.id
    if not id and tt.GetItem then
        local _, link = tt:GetItem()
        id = link and tonumber(tostring(link):match("item:(%d+)"))
    end
    if not id or isSecret(id) then return end
    local lines = P.TooltipLines(id)
    if not lines then return end
    for _, l in ipairs(lines) do tt:AddLine(l[1], l[2], l[3], l[4]) end
    if tt.Show then tt:Show() end
end
P._onTip = onTip
OMQ:On("READY", function()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
            local ok, err = pcall(onTip, tt, data)
            if not ok then OMQ:Error("price tooltip", err) end
        end)
    elseif GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", function(tt)
            local ok, err = pcall(onTip, tt, nil)
            if not ok then OMQ:Error("price tooltip", err) end
        end)
    end
end)

ev:SetScript("OnEvent", function(_, event)
    local ok, err = pcall(function()
        if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
            local n = P.LearnVendor()
            if event == "MERCHANT_SHOW" and C_Timer and C_Timer.After then
                C_Timer.After(1, function()                      -- the list may be filled a moment later
                    P.LearnVendor()
                end)
            end
        elseif event == "AUCTION_HOUSE_SHOW" then
            if P.AutoOn() and C_Timer and C_Timer.After then
                C_Timer.After(P.START_DELAY, function()
                    local at = P.ScannedAt()
                    if scan then return end
                    if not at or stamp() - at > P.MAX_AGE then P.Start(false)
                    else                                      -- fresh: the dump of a moment ago serves this window
                        sessionAt = now()
                        local H = helper()
                        if H and H.Evaluate then pcall(H.Evaluate) end
                        if H and H.Refresh then pcall(H.Refresh) end
                        if H and H.Pump then pcall(H.Pump) end
                    end
                end)
            end
        elseif event == "AUCTION_HOUSE_CLOSED" then
            sessionAt = nil
            if scan then finish(false, "the window closed") end
        elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
            if scan and scan.state == "requested" then beginReading() end
        end
    end)
    if not ok then OMQ:Error("prices", err) end
end)

local tick, acc = CreateFrame("Frame"), 0
tick:SetScript("OnUpdate", function(_, dt)
    if not scan then return end
    acc = acc + (dt or 0)
    if acc < (scan.state == "reading" and 0.05 or 0.5) then return end
    acc = 0
    local ok, err = pcall(P.Step)
    if not ok then OMQ:Error("prices", err) end
end)

local function ago(at)
    local d = stamp() - at
    if d < 120 then return "just now" end
    if d < 7200 then return math.floor(d / 60) .. " min ago" end
    if d < 172800 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " d ago"
end
P.Ago = ago

OMQ:RegisterCommand("prices", function(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "scan" then
        local ok, why = P.Start(true)
        if not ok then OMQ:Print("prices: " .. tostring(why)) end
        return
    end
    if arg == "cancel" then P.Cancel(); OMQ:Print("prices: scan stopped"); return end
    if arg == "sample" then                                  -- the first auctions of the dump as the game gives them
        local api = A()
        local n = api and api.GetNumReplicateItems and tonumber(api.GetNumReplicateItems()) or 0
        OMQ:Print("prices: the dump holds " .. n .. " auctions")
        for i = 1, math.min(5, n) do
            local ok, name, _, count, _, _, _, _, minBid, _, buyout, _, _, _, _, _, _, itemID = pcall(api.GetReplicateItemInfo, i)
            if ok then OMQ:Print(string.format("  %d: %s x%s, bid %s, buyout %s, item %s", i, tostring(name), tostring(count), tostring(minBid), tostring(buyout), tostring(itemID))) end
        end
        return
    end
    local id = tonumber(arg)
    if id then
        local a, q, at = P.Auction(id)
        local v = P.Vendor(id)
        OMQ:Print(string.format("prices: item %d - auction %s%s, vendor %s", id, a and (OMQ.AuctionHelper and OMQ.AuctionHelper.Money(a) or a) or "none",
            q and q > 0 and (" (" .. q .. " on offer)") or "", v and (OMQ.AuctionHelper and OMQ.AuctionHelper.Money(v) or v) or "unknown"))
        return
    end
    local at = P.ScannedAt()
    local nv = 0
    for _ in pairs(vendorStore()) do nv = nv + 1 end
    local line = string.format("prices: %d auction items %s, %d vendor prices learned", P.Count(), at and ("scanned " .. ago(at)) or "- not scanned yet", nv)
    if scan then line = line .. string.format("; scan running (%s): %d of %d auctions read", scan.state, scan.results, scan.n) end
    if P.last then line = line .. string.format("; last scan %s: %d auctions, %d items, %.0f s%s", P.last.ok and "complete" or "failed", P.last.results, P.last.items, P.last.secs, P.last.why and (" (" .. P.last.why .. ")") or "") end
    OMQ:Print(line .. ".  /omq prices scan | cancel | sample | <item id>")
end, "auction prices: /omq prices | scan | cancel | sample | <item id>")
