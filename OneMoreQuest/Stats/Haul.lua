-- One More Quest: every weapon and armor piece a character ever got
-- Kept in the per-character book of Stats/Tally.lua (book.gear), one entry per item and random suffix:
-- what it is (stats as at the find), when and where it was first found, from what, with which dads,
-- how often, and when and on how many days it was worn. At the first start the bags, the body and (at
-- the first bank visit) the bank are taken in once as "before". Gray items get a short entry.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local T = OMQ.Tally
local H = {}
OMQ.Haul = H

local MAX_ITEMS = 5000
local SOURCE_TTL = 120     -- seconds a loot window slot remembers where its item came from
local PUSH_WINDOW = 3      -- seconds after a quest turn-in in which a pushed item is its reward
local ROLL_WINDOW = 15     -- seconds between "You won" and the item in the bags
local KILL_WINDOW = 60     -- a won roll belongs to the last kill of this window
local FILL_TRIES = 5       -- item data not loaded yet: ask again every 2 seconds
local WEAR_EVERY = 600     -- worn days are counted at login, on a change and every 10 minutes
local GEAR_CLASS = { [2] = true, [4] = true }   -- weapon, armor (rings, necks, cloaks, trinkets too)

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function str(v) return type(v) == "string" and ok(v) and v ~= "" end
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2)
end
local function note(key) T.diag[key] = (T.diag[key] or 0) + 1 end
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

-- "|cff...|Hitem:2169:0:0:0:0:0:-12:5:...|h[Name]|h|r" -> 2169, -12, the link
local function parseLink(text)
    if not str(text) then return nil end
    local s = text:match("|Hitem:([%-%d:]*)") or text:match("^item:([%-%d:]*)")
    if not s then return nil end
    local f, i = {}, 0
    for part in (s .. ":"):gmatch("([^:]*):") do i = i + 1; f[i] = part end
    local id = tonumber(f[1])
    if not id then return nil end
    local link = text:match("(|c[^|]*|Hitem:.-|h.-|h|r)") or text:match("(|Hitem:.-|h.-|h)") or text
    return id, tonumber(f[7] or "") or 0, link
end
H.ParseLink = parseLink
local function keyOf(id, sfx) return sfx ~= 0 and (id .. ":" .. sfx) or tostring(id) end
H.Key = keyOf

local QUALITY = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5 }
local function quality(link)
    local q = tonumber(link:match("|cnIQ(%d):") or "")
    if q then return q end
    local hex = link:match("|cff(%x%x%x%x%x%x)|Hitem:")
    return hex and QUALITY[hex:lower()]
end

local function instant(link)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local id, _, _, loc, _, cls, sub = call(fn, link)
    if not id then return nil end
    return cls, sub, loc
end

local STAT = {
    ITEM_MOD_STRENGTH_SHORT = "str", ITEM_MOD_AGILITY_SHORT = "agi", ITEM_MOD_STAMINA_SHORT = "sta",
    ITEM_MOD_INTELLECT_SHORT = "int", ITEM_MOD_SPIRIT_SHORT = "spi", RESISTANCE0_NAME = "arm",
    ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "dps", RESISTANCE1_NAME = "hol", RESISTANCE2_NAME = "fir",
    RESISTANCE3_NAME = "nat", RESISTANCE4_NAME = "fro", RESISTANCE5_NAME = "sha", RESISTANCE6_NAME = "arc",
    ITEM_MOD_ATTACK_POWER_SHORT = "ap", ITEM_MOD_SPELL_POWER_SHORT = "sp", ITEM_MOD_CRIT_RATING_SHORT = "crit",
    ITEM_MOD_HIT_RATING_SHORT = "hit", ITEM_MOD_MANA_REGENERATION_SHORT = "mp5",
    ITEM_MOD_HEALTH_REGENERATION_SHORT = "hp5", ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "def",
}
local function stats(link)
    local fn = (C_Item and C_Item.GetItemStats) or GetItemStats
    local t = call(fn, link)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == "string" and num(v) and v ~= 0 then
            local short = STAT[k] or (k:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):lower())
            out[short] = math.floor(v * 10 + 0.5) / 10
        end
    end
    return out
end

-- name, quality, item level, required level and stats once the game has the item loaded
local function describe(e, link)
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, _, q, il, rl = call(fn, link)
    if not str(name) then return false end
    e.nm = e.nm or name
    if num(q) then e.q = q end
    if e.q == 0 then return true end          -- short entry: no stats
    if num(il) and il > 0 then e.il = il end
    if num(rl) and rl > 0 then e.rl = rl end
    local st = stats(link)
    if not st then return false end
    e.st = st
    return true
end
local function fill(e, link, tries)
    if describe(e, link) then return end
    if tries == 0 and C_Item and C_Item.RequestLoadItemDataByID then call(C_Item.RequestLoadItemDataByID, e.id) end
    if tries >= FILL_TRIES then note("gear.nostats"); return end
    C_Timer.After(2, function() pcall(fill, e, link, tries + 1) end)
end
H._Fill = fill

local function myLevel() local l = call(UnitLevel, "player"); return num(l) and l or 1 end
local function book()
    local b = T.Book and T.Book()
    if not b then return nil end
    b.gear = b.gear or {}
    return b
end

-- the dads (addon users) in the group right now, by GUID
local function dads()
    local out
    for g in pairs(T.Mates()) do
        if OMQ.users and OMQ.users[g] then out = out or {}; out[#out + 1] = g end
    end
    if out then table.sort(out) end
    return out
end

----------------------------------------------------------------------
-- Where an item came from
----------------------------------------------------------------------
local slots = {}            -- [itemID] = { kind, from, guid, at } from the open loot window
local won = {}              -- [itemID] = time of "You won"
local questAt, questID = -100, nil
local questOpen, questOpenID = false, nil   -- the reward page of a quest is open
local pushed = {}                           -- items pushed as "other" just now: { e, at }
local merchantOpen, mailOpen = false, false

local function onLootOpened()
    if not (GetNumLootItems and GetLootSlotLink) then return end
    local n = call(GetNumLootItems)
    if not num(n) then return end
    local fishing = IsFishingLoot and call(IsFishingLoot)
    for i = 1, n do
        local id = parseLink(call(GetLootSlotLink, i))
        if id then
            local guid = GetLootSourceInfo and call(GetLootSourceInfo, i)
            local kind, from = T.ParseGuid(guid)
            if ok(fishing) and fishing then kind = "fish" end
            slots[id] = { kind = kind, from = from, guid = guid, at = GetTime() }
        end
    end
end
H._LootOpened = onLootOpened

local KINDS = { Creature = "drop", Vehicle = "drop", GameObject = "chest", Item = "container", fish = "fish" }
-- src, from (npc, object or quest id), the cached unit of a mob
local function origin(id, how)
    local now = GetTime()
    if how == "before" or how == "craft" then return how end
    if how == "push" then
        if now - questAt <= PUSH_WINDOW then return "quest", questID end
        if questOpen then return "quest", questOpenID end
        if merchantOpen then return "vendor" end
        if mailOpen then return "mail" end
        return "other"
    end
    local s = slots[id]
    if s and now - s.at <= SOURCE_TTL then
        slots[id] = nil
        local src = KINDS[s.kind] or "other"
        if src == "drop" then
            local e = T.Lookup and T.Lookup(s.guid)
            if T.IsBoss(s.from) or (e and e.rank == "boss") then src = "boss" end
            return src, s.from, e
        end
        return src, s.from
    end
    if won[id] and now - won[id] <= ROLL_WINDOW then
        won[id] = nil
        local k = T.lastKill
        if k and now - k.at <= KILL_WINDOW then return "roll", k.id, T.Lookup and T.Lookup(k.guid) end
        return "roll"
    end
    return "other"
end
H._Origin = origin

----------------------------------------------------------------------
-- Entries
----------------------------------------------------------------------
-- how: "loot" (loot message), "push" (quest, vendor, mail), "craft", "before" (the first start), "other"
function H:Add(text, how)
    local id, sfx, link = parseLink(text)
    if not id then return nil end
    local cls, sub, loc = instant(link)
    if not GEAR_CLASS[cls] then return nil end
    local b = book()
    if not b then return nil end
    local key = keyOf(id, sfx)
    local e = b.gear[key]
    if e then
        e.n = e.n + 1
        e.ld = time()
        if how ~= "before" then origin(id, how) end   -- use up the remembered source
        note("gear.again")
        return e
    end
    b.gearN = b.gearN or count(b.gear)
    if b.gearN >= MAX_ITEMS then note("gear.full"); return nil end
    e = { id = id, n = 1, t = time(), l = myLevel() }
    if sfx ~= 0 then e.sfx = sfx end
    if str(loc) then e.slot = loc end
    e.q = quality(link)
    if how ~= "before" then e.zn = T.map and T.ZoneOf and T.ZoneOf(T.map) or nil end
    if e.q ~= 0 then
        e.cl, e.sc = cls, num(sub) and sub or nil
        local src, from, unit = origin(id, how)
        e.src, e.from = src, from
        if unit and num(unit.lvl) then e.fl = unit.lvl end
        if how ~= "before" then
            e.dy = count(b.days)
            e.z = T.map
            local sz = call(GetSubZoneText)
            if str(sz) then e.sz = sz end
            local _, kind, _, _, _, _, _, iid = call(GetInstanceInfo)
            if (kind == "party" or kind == "raid") and num(iid) then e.iid = iid; e.ins = #b.dungeons end
            e.g = dads()
        end
    elseif how ~= "before" then
        origin(id, how)
    end
    b.gear[key] = e
    b.gearN = b.gearN + 1
    if how == "push" and e.src == "other" then pushed[#pushed + 1] = { e = e, at = GetTime() } end
    fill(e, link, 0)
    note("gear.new")
    note("gear." .. (e.src or "short"))
    return e
end

----------------------------------------------------------------------
-- Worn and the first start
----------------------------------------------------------------------
local function wear(slot)
    local link = GetInventoryItemLink and call(GetInventoryItemLink, "player", slot)
    if not str(link) then return end
    local b = book()
    if not b then return end
    local id, sfx = parseLink(link)
    if not id then return end
    local e = b.gear[keyOf(id, sfx)] or H:Add(link, b.gearSeed and "other" or "before")
    if not e then return end
    local today = T.Today()
    if not e.w then e.w = time(); note("gear.worn") end
    if e.wl ~= today then e.wd = (e.wd or 0) + 1; e.wl = today end
end
local function wearAll() for s = 1, 19 do wear(s) end end
H._Wear, H._WearAll = wear, wearAll

local function bagItems(first, last, out)
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemLink) then return end
    for bag = first, last do
        local n = call(C_Container.GetContainerNumSlots, bag)
        for s = 1, num(n) and n or 0 do
            local link = call(C_Container.GetContainerItemLink, bag, s)
            if str(link) then out[#out + 1] = link end
        end
    end
end

local function seed()
    local b = book()
    if not b or b.gearSeed then return end
    local list = {}
    for s = 1, 19 do
        local link = GetInventoryItemLink and call(GetInventoryItemLink, "player", s)
        if str(link) then list[#list + 1] = link end
    end
    bagItems(0, NUM_BAG_SLOTS or 4, list)
    for _, link in ipairs(list) do H:Add(link, "before") end
    b.gearSeed = time()
    note("gear.seed")
end
local function seedBank()
    local b = book()
    if not b or b.gearBank then return end
    local list, bags = {}, NUM_BAG_SLOTS or 4
    bagItems(BANK_CONTAINER or -1, BANK_CONTAINER or -1, list)
    bagItems(bags + 1, bags + (NUM_BANKBAGSLOTS or 6), list)
    for _, link in ipairs(list) do if not b.gear[keyOf(parseLink(link))] then H:Add(link, "before") end end
    b.gearBank = time()
    note("gear.bank")
end
H._Seed, H._SeedBank = seed, seedBank

----------------------------------------------------------------------
-- Loot messages
----------------------------------------------------------------------
local pats
local function patterns()
    if pats then return pats end
    local function list(...)
        local out = {}
        for i = 1, select("#", ...) do local p = T.ToPattern((select(i, ...))); if p then out[#out + 1] = p end end
        return out
    end
    pats = {
        won = list(LOOT_ROLL_YOU_WON),
        craft = list(LOOT_ITEM_CREATED_SELF_MULTIPLE, LOOT_ITEM_CREATED_SELF),
        loot = list(LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF),
        push = list(LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF),
    }
    return pats
end
local function matches(list, msg)
    for _, p in ipairs(list) do if msg:match(p) then return true end end
    return false
end

local function onLootMsg(msg)
    if not str(msg) then return end
    local p = patterns()
    if matches(p.won, msg) then
        local id = parseLink(msg)
        if id then won[id] = GetTime() end
        return
    end
    for _, how in ipairs({ "craft", "loot", "push" }) do
        if matches(p[how], msg) then H:Add(msg, how); return end
    end
end
H._LootMsg = onLootMsg

----------------------------------------------------------------------
-- Test output (hidden: /omq tally gear)
----------------------------------------------------------------------
local function tally(field)
    local out = {}
    for _, e in pairs((book() or {}).gear or {}) do
        local k = e[field]
        if k ~= nil then out[k] = (out[k] or 0) + 1 end
    end
    local list = {}
    for k, n in pairs(out) do list[#list + 1] = tostring(k) .. "=" .. n end
    table.sort(list)
    return table.concat(list, " ")
end

function H:Line()
    local b = book()
    if not b then return end
    local nostats, worn = 0, 0
    for _, e in pairs(b.gear) do
        if e.q ~= 0 and not e.st then nostats = nostats + 1 end
        if e.w then worn = worn + 1 end
    end
    print(string.format("  gear %d items, without stats %d, worn %d, sources %s", count(b.gear), nostats, worn, tally("src")))
end

function H:Report()
    local b = book()
    if not b then return end
    OMQ:Print("gear " .. count(b.gear) .. " items" .. (b.gearSeed and "" or ", not taken in yet"))
    print("  quality " .. tally("q"))
    print("  sources " .. tally("src"))
    H:Line()
    local list = {}
    for _, e in pairs(b.gear) do list[#list + 1] = e end
    table.sort(list, function(a, c) return a.t > c.t end)
    for i = 1, math.min(3, #list) do
        local e = list[i]
        local st = {}
        for k, v in pairs(e.st or {}) do st[#st + 1] = k .. " " .. v end
        table.sort(st)
        print(string.format("  %s (%d) q%s %s %s from %s, zone %s, level %d, %s", tostring(e.nm or "?"), e.id,
            tostring(e.q), tostring(e.slot or "?"), tostring(e.src or "short"), tostring(e.from or "-"),
            tostring(e.zn or "-"), e.l or 0, table.concat(st, ", ")))
    end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
-- the reward can come before the turn-in event: items pushed just before it were its reward
local function questDone(id)
    questAt, questID = GetTime(), num(id) and id or nil
    for _, p in ipairs(pushed) do
        if questAt - p.at <= PUSH_WINDOW and p.e.src == "other" then p.e.src, p.e.from = "quest", questID; note("gear.quest.late") end
    end
    pushed = {}
end
local function questPage()
    questOpen = true
    local id = GetQuestID and call(GetQuestID)
    questOpenID = num(id) and id > 0 and id or nil
end
H._QuestDone = questDone

local EVENTS = {
    CHAT_MSG_LOOT = onLootMsg,
    LOOT_OPENED = onLootOpened,
    QUEST_TURNED_IN = questDone,
    QUEST_COMPLETE = questPage,
    QUEST_FINISHED = function() questOpen = false end,
    MERCHANT_SHOW = function() merchantOpen = true end,
    MERCHANT_CLOSED = function() merchantOpen = false end,
    MAIL_SHOW = function() mailOpen = true end,
    MAIL_CLOSED = function() mailOpen = false end,
    BANKFRAME_OPENED = seedBank,
    PLAYER_EQUIPMENT_CHANGED = function(slot) if num(slot) then wear(slot) end end,
}

local frame = CreateFrame("Frame")
for e in pairs(EVENTS) do pcall(frame.RegisterEvent, frame, e) end
frame:SetScript("OnEvent", function(_, event, ...)
    if not T.ready then return end
    local fine, err = pcall(EVENTS[event], ...)
    if not fine then note("err.gear." .. event); OMQ:Error("gear " .. event, err) end
end)

OMQ:On("READY", function()
    C_Timer.After(5, function()
        local fine, err = pcall(function() seed(); wearAll() end)
        if not fine then note("err.gear.seed"); OMQ:Error("gear seed", err) end
    end)
    C_Timer.NewTicker(WEAR_EVERY, function() pcall(wearAll) end)
end)
