-- One More Quest: ledger
-- Milestones read from the per-character counters (Stats/Tally.lua). Each entry has a tab, a goal and
-- either one threshold or up to four tiers. Nothing is shown before level 10; at level 10 everything
-- reached so far is granted at once. A tab opens with its first entry. The book keeps only when an
-- entry was reached (book.cards), which tab opened when (book.tabs) and what others showed (book.seen).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local L = {}
OMQ.Ledger = L

L.MIN_LEVEL = 10
L.MAX_LEVEL = 60
local CHECK_EVERY = 60
local EXPLORE_CACHE = 600

local function ok(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function num(v) return type(v) == "number" and ok(v) end
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    return unpack(r, 2)
end
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
local function pn(t, k) local p = t and t[k]; return p and p.n or 0 end
local function pm(t, k) local p = t and t[k]; return p and p.m or 0 end
local dateFn = date or (os and os.date)

L.diag = {}
local function note(k) L.diag[k] = (L.diag[k] or 0) + 1 end

----------------------------------------------------------------------
-- Tabs and entries
----------------------------------------------------------------------
L.TABS = {
    { id = "leveling", name = "Leveling" }, { id = "foes", name = "Foes" }, { id = "quests", name = "Quests" },
    { id = "places", name = "Places" }, { id = "npcs", name = "NPCs" }, { id = "comrades", name = "Comrades" },
    { id = "dungeons", name = "Dungeons" }, { id = "pvp", name = "PvP" }, { id = "feats", name = "Feats" },
    { id = "mishaps", name = "Mishaps" }, { id = "summary", name = "Summary" },
}

local I = "Interface\\Icons\\"
L.CARDS = {}
L.byId = {}
local function add(c)
    c.icon = c.icon and (I .. c.icon) or (I .. "INV_Misc_QuestionMark")
    L.CARDS[#L.CARDS + 1] = c
    L.byId[c.id] = c
    return c
end
-- one threshold: q = quality (1 white ... 5 orange)
local function one(tab, id, title, text, icon, q, value, need)
    return add({ tab = tab, id = id, title = title, text = text, icon = icon, q = q, value = value, need = need or 1 })
end
-- up to four tiers, the first one in quality `start` (default green)
local function tiers(tab, id, title, text, icon, list, value, start)
    return add({ tab = tab, id = id, title = title, text = text, icon = icon, tiers = list, start = start or 2, value = value })
end
local function yes(v) return v and 1 or 0 end

-- shared values
local function lvl(_, ctx) return ctx.level end
local function deathsBy(b, why) local n = 0; for _, d in ipairs(b.deaths or {}) do if d.why == why then n = n + 1 end end; return n end
local function dads(b)
    local out = {}
    for g, p in pairs(b.people or {}) do if p.dad then out[#out + 1] = p end end
    return out
end
local function bestDad(b, field, scale)
    local best, who = 0, nil
    for _, p in ipairs(dads(b)) do
        local v = (p[field] or 0) / (scale or 1)
        if v > best then best, who = v, p.nm end
    end
    return best, who
end
local function npcKinds(b, kind)
    local distinct, visits = 0, 0
    for _, n in pairs(b.npcs or {}) do
        if n.k and n.k[kind] then distinct = distinct + 1; visits = visits + (n.n or 0) end
    end
    return distinct, visits
end

-- Leveling
local T0 = "leveling"
one(T0, "lv10", "Double Digits", "Reach level 10", "INV_Misc_Book_09", 1, lvl, 10)
tiers(T0, "lvway", "On the Way", "Reach level %s", "INV_Misc_Map_01", { 20, 30, 40, 50 }, lvl)
one(T0, "lv60", "Sixty!", "Reach level 60", "Spell_Holy_PowerInfusion", 5, lvl, 60)
one(T0, "rocket", "Rocket", "Gain a level in less than one hour of play (from level 10)", "Spell_Fire_SelfDestruct", 3, function(b)
    local lv = b.levels or {}
    for l = 11, L.MAX_LEVEL do
        local a, c = lv[l - 1], lv[l]
        if a and c and a.secs and c.secs and c.secs - a.secs > 0 and c.secs - a.secs < 3600 then return 1 end
    end
    return 0
end)
tiers(T0, "streak", "Loyal Soul", "Play on %s days in a row", "INV_Misc_PocketWatch_01", { 3, 7, 14, 30 }, function()
    local _, best = OMQ.Tally:Streak()
    return best or 0
end)
one(T0, "marathon", "Marathon", "Play 4 hours on one day", "INV_Drink_04", 3, function(b)
    for _, d in pairs(b.days or {}) do if (d.s or 0) >= 4 * 3600 then return 1 end end
    return 0
end)
tiers(T0, "spell", "Favourite Spell", "Cast one spell %s times", "INV_Misc_Book_11", { 1000, 5000, 10000, 25000 }, function(b)
    local best, id = 0, nil
    for sid, n in pairs(b.spells or {}) do if n > best then best, id = n, sid end end
    local name = id and C_Spell and call(C_Spell.GetSpellName, id)
    return best, ok(name) and name or nil
end)
one(T0, "mount", "Fast Boy", "Ride your first mount", "Ability_Mount_RidingHorse", 4, function(b) return yes(b.firsts and b.firsts.mount) end)
tiers(T0, "craft", "Master Crafter", "Raise a profession to %s", "Trade_BlackSmithing", { 75, 150, 225, 300 }, function(b, ctx)
    local best = 0
    for _, s in pairs(ctx.prof or {}) do if s > best then best = s end end
    return best
end)
tiers(T0, "gather", "Gatherer", "Gather %s herbs, ores or skins", "Trade_Herbalism", { 100, 500, 1500, 3000 }, function(b)
    local g = b.gather or {}
    return (g.herb or 0) + (g.mine or 0) + (g.skin or 0)
end)
tiers(T0, "fish", "Angler", "Catch %s fish", "Trade_Fishing", { 50, 250, 1000 }, function(b) return b.gather and b.gather.fish or 0 end)

-- Foes
local T1 = "foes"
local function kt(key) return function(b) return pn(b.kills.type, key) end end
tiers(T1, "kills", "Carnage", "Defeat %s foes", "Ability_Warrior_Cleave", { 1000, 5000, 10000, 20000 }, function(b) return b.kills.total or 0 end)
tiers(T1, "beast", "Beast Hunter", "Slay %s beasts", "Ability_Hunter_Pet_Wolf", { 100, 500, 1500, 4000 }, kt("beast"))
tiers(T1, "humanoid", "Bandit's Bane", "Slay %s humanoids", "INV_Misc_Bandana_03", { 100, 500, 1500, 4000 }, kt("humanoid"))
tiers(T1, "undead", "Grave Robber", "Slay %s undead", "Spell_Shadow_RaiseDead", { 50, 250, 1000, 2500 }, kt("undead"))
tiers(T1, "demon", "Demon Ward", "Slay %s demons", "Spell_Shadow_SummonImp", { 25, 150, 500, 1000 }, kt("demon"))
tiers(T1, "elemental", "Elemental Tamer", "Slay %s elementals", "Spell_Fire_Elemental_Totem", { 25, 150, 500, 1000 }, kt("elemental"))
tiers(T1, "dragon", "Dragon Slayer", "Slay %s dragonkin", "INV_Misc_Head_Dragon_01", { 10, 100, 300, 750 }, kt("dragonkin"))
tiers(T1, "elite", "Elite Hunter", "Slay %s elites outside of dungeons", "Ability_Warrior_BattleShout", { 10, 100, 300, 750 }, function(b)
    local r = b.kills.rankOut or {}
    return pn(r, "elite") + pn(r, "rareelite")
end)
tiers(T1, "rare", "Rare Collector", "Slay %s rare foes", "INV_Misc_Gem_Diamond_01", { 1, 5, 15 }, function(b)
    return pn(b.kills.rank, "rare") + pn(b.kills.rank, "rareelite")
end, 3)
one(T1, "dare", "Dare", "Land the killing blow on a red foe", "Ability_Warrior_Challange", 4, function(b)
    return pm(b.kills.color, "red") + pm(b.kills.color, "skull")
end)
one(T1, "lowbie", "Lowbie Basher", "Slay 100 gray foes", "INV_Misc_Bone_HumanSkull_01", 2, function(b) return pn(b.kills.color, "gray") end, 100)
one(T1, "critter", "Pest Control", "Slay 50 critters", "Ability_Hunter_Pet_Crab", 2, kt("critter"), 50)
one(T1, "fullbag", "Full Pockets", "Slay 100 foes with full bags", "INV_Misc_Bag_08", 3, function(b) return b.kills.fullbag or 0 end, 100)

-- Quests
local T2 = "quests"
local function questsBy(b, fn) local n = 0; for id, q in pairs(b.quests or {}) do if fn(q, id) then n = n + 1 end end; return n end
tiers(T2, "quests", "Busy Bee", "Complete %s quests", "INV_Misc_Note_01", { 50, 200, 500, 800 }, function(b) return count(b.quests) end)
one(T2, "teamwork", "Teamwork", "Complete 50 quests with another dad in the group", "INV_Scroll_03", 3, function(b)
    return questsBy(b, function(q)
        for _, g in ipairs(q.g or {}) do local p = b.people[g]; if p and p.dad then return true end end
        return false
    end)
end, 50)
local function questsPerMap(b)
    local per = {}
    for _, q in pairs(b.quests or {}) do if q.m then per[q.m] = (per[q.m] or 0) + 1 end end
    return per
end
one(T2, "questout", "Quested Out", "Complete 30 quests in one area", "INV_Misc_Map02", 3, function(b)
    local best = 0
    for _, n in pairs(questsPerMap(b)) do if n > best then best = n end end
    return best
end, 30)
one(T2, "questworld", "Citizen of the World", "Complete quests in 10 different areas", "INV_Misc_Map_01", 3, function(b)
    return count(questsPerMap(b))
end, 10)
one(T2, "night", "Night Shift", "Complete 10 quests after midnight in one evening", "Spell_Nature_Starfall", 4, function(b)
    if not dateFn then return 0 end
    local per, best = {}, 0
    for _, q in pairs(b.quests or {}) do
        local h = q.t and tonumber(dateFn("%H", q.t))
        if h and h < 5 then
            local key = dateFn("%Y-%m-%d", q.t - 6 * 3600)
            per[key] = (per[key] or 0) + 1
            if per[key] > best then best = per[key] end
        end
    end
    return best
end, 10)
one(T2, "evening", "Hero after Work", "Complete 20 quests on one day", "INV_Misc_PocketWatch_02", 4, function(b)
    local best = 0
    for _, d in pairs(b.days or {}) do if (d.q or 0) > best then best = d.q end end
    return best
end, 20)

-- Places
local T3 = "places"
local CONTINENTS = { [1414] = true, [1415] = true }
local CAPITALS = { Alliance = { 1453, 1455, 1457 }, Horde = { 1454, 1456, 1458 } }
tiers(T3, "zones", "Wanderlust", "Visit %s zones", "Ability_Tracking", { 10, 20, 30, 35 }, function(b) return count(b.zones) end)
one(T3, "sea", "Across the Sea", "Set foot on the other continent", "Spell_Frost_SummonWaterElemental", 2, function(b)
    if not (C_Map and C_Map.GetMapInfo) then return 0 end
    local seen = {}
    for z in pairs(b.zones or {}) do
        local id = z
        for _ = 1, 4 do
            local info = call(C_Map.GetMapInfo, id)
            if type(info) ~= "table" then break end
            if CONTINENTS[id] then seen[id] = true; break end
            id = info.parentMapID
            if not num(id) or id == 0 then break end
        end
    end
    return count(seen) >= 2 and 1 or 0
end)
one(T3, "capitals", "City Kid", "Visit every capital of your faction", "Ability_Warrior_RallyingCry", 3, function(b, ctx)
    local list = CAPITALS[ctx.faction or ""]
    if not list then return 0 end
    for _, id in ipairs(list) do if not (b.maps[id] or (b.zones and b.zones[id])) then return 0 end end
    return 1
end)
-- the map overlays are asked again when a zone is new or after a while
local explored, exploredAt, exploredZones = 0, -EXPLORE_CACHE, -1
tiers(T3, "explore", "Cartographer", "Uncover %s map areas", "INV_Misc_Spyglass_02", { 50, 150, 300, 450 }, function(b)
    local zones = count(b.zones)
    if zones == exploredZones and GetTime() - exploredAt < EXPLORE_CACHE then return explored end
    local n = 0
    for z in pairs(b.zones or {}) do n = n + (OMQ.Tally:Explored(z) or 0) end
    explored, exploredAt, exploredZones = n, GetTime(), zones
    return n
end)
one(T3, "home", "Home Turf", "Spend 10 hours in one area", "INV_Misc_Rune_01", 2, function(b)
    local best = 0
    for _, m in pairs(b.maps or {}) do if (m.s or 0) > best then best = m.s end end
    return best
end, 10 * 3600)
tiers(T3, "flights", "Frequent Flyer", "Take %s flights", "Ability_Hunter_EagleEye", { 25, 100, 250 }, function(b) return b.move.flights or 0 end)
one(T3, "foot", "Wayfarer", "Walk 100,000 yards", "Ability_Rogue_Sprint", 2, function(b) return b.move.foot or 0 end, 100000)
one(T3, "swim", "Water Rat", "Swim 5,000 yards", "Spell_Shadow_DemonBreath", 2, function(b) return b.move.swim or 0 end, 5000)
one(T3, "jumps", "Bunny Hop", "Jump 1,000 times", "Ability_Druid_Dash", 4, function(b) return b.move.jumps or 0 end, 1000)

-- NPCs
local T4 = "npcs"
local LEADERS = { 4949, 3057, 10181, 10540, 1748, 1747, 2784, 7999, 7937 }
tiers(T4, "npcs", "Chatterbox", "Talk to %s different people", "INV_Letter_02", { 50, 150, 300, 450 }, function(b) return count(b.npcs) end)
one(T4, "inn", "Regular", "Visit the same innkeeper 20 times", "INV_Drink_05", 4, function(b)
    local best = 0
    for _, n in pairs(b.npcs or {}) do if n.k and n.k.innkeeper and (n.n or 0) > best then best = n.n end end
    return best
end, 20)
one(T4, "vendor", "Bargain Hunter", "Visit vendors 100 times", "INV_Misc_Coin_01", 2, function(b) local _, v = npcKinds(b, "vendor"); return v end, 100)
one(T4, "trainer", "Eternal Student", "Learn from 10 different trainers", "INV_Misc_Book_08", 3, function(b) return (npcKinds(b, "trainer")) end, 10)
tiers(T4, "flightm", "Air Traffic Control", "Talk to %s flight masters", "Ability_Hunter_Pet_WindSerpent", { 10, 20, 30 }, function(b) return (npcKinds(b, "flight")) end)
one(T4, "bank", "Hoarder", "Visit the bank 50 times", "INV_Box_02", 2, function(b) local _, v = npcKinds(b, "bank"); return v end, 50)
one(T4, "leader", "Humble Servant", "Speak with a faction leader", "Spell_Holy_SealOfWisdom", 2, function(b)
    for _, id in ipairs(LEADERS) do if b.npcs[id] then return 1 end end
    return 0
end)
tiers(T4, "aucp", "Auctioneer", "Post %s auctions", "INV_Misc_Coin_02", { 10, 50, 200, 500 }, function() return OMQ.Tally:GameStat("aucp") or 0 end)
tiers(T4, "aucg", "Cash Cow", "Earn %s gold at the auction house", "INV_Misc_Coin_03", { 100, 500, 1000, 5000 }, function()
    return math.floor((OMQ.Tally:GameStat("aucg") or 0) / 10000)
end)

-- Comrades
local T5 = "comrades"
one(T5, "dad", "Not Alone", "Group up with another dad", "Spell_Holy_PrayerOfFortitude", 1, function(b) return #dads(b) end)
tiers(T5, "together", "Inseparable", "Play %s hours with the same dad", "Spell_Holy_Heal", { 10, 50, 100, 250 }, function(b) return bestDad(b, "s", 3600) end)
one(T5, "qpartner", "Quest Partner", "Complete 100 quests with the same dad", "INV_Scroll_01", 3, function(b) return bestDad(b, "q") end, 100)
one(T5, "sunk", "Sunk Together", "Die 10 times together with a dad", "Spell_Shadow_DeathScream", 2, function(b) return bestDad(b, "d") end, 10)
tiers(T5, "res", "Soul Saver", "Resurrect %s group members", "Spell_Holy_Resurrection", { 1, 10, 50 }, function(b) return b.support.res or 0 end)
tiers(T5, "help", "Helping Hand", "Buff or heal group members %s times", "Spell_Holy_Renew", { 500, 2000, 5000 }, function(b)
    return (b.support.buffOthers or 0) + (b.support.healOthers or 0)
end)
one(T5, "dance", "Dance Crew", "Use 25 emotes on dads", "Spell_Holy_MindVision", 3, function(b)
    local n = 0
    for _, p in ipairs(dads(b)) do for _, c in pairs(p.emo or {}) do n = n + c end end
    return n
end, 25)
one(T5, "strangers", "Strange Friends", "Group with 10 players who are not dads", "Spell_Holy_SealOfSalvation", 2, function(b)
    local n = 0
    for _, p in pairs(b.people or {}) do if not p.dad then n = n + 1 end end
    return n
end, 10)

-- Dungeons: one entry per final boss (wings count on their own)
local T6 = "dungeons"
L.BOSSES = {
    { 389, "Ragefire Chasm", 11520, "Taragaman the Hungerer", 16 }, { 36, "The Deadmines", 639, "Edwin VanCleef", 21 },
    { 43, "Wailing Caverns", 3654, "Mutanus the Devourer", 22 }, { 33, "Shadowfang Keep", 4275, "Archmage Arugal", 26 },
    { 48, "Blackfathom Deeps", 4829, "Aku'mai", 28 }, { 34, "The Stockade", 1716, "Bazil Thredd", 28 },
    { 90, "Gnomeregan", 7800, "Mekgineer Thermaplugg", 33 }, { 47, "Razorfen Kraul", 4421, "Charlga Razorflank", 30 },
    { 189, "Scarlet Graveyard", 4543, "Bloodmage Thalnos", 33 }, { 189, "Scarlet Library", 6487, "Arcanist Doan", 36 },
    { 189, "Scarlet Armory", 3975, "Herod", 39 }, { 189, "Scarlet Cathedral", 3977, "High Inquisitor Whitemane", 42 },
    { 129, "Razorfen Downs", 7358, "Amnennar the Coldbringer", 40 }, { 70, "Uldaman", 2748, "Archaedas", 47 },
    { 209, "Zul'Farrak", 7267, "Chief Ukorz Sandscalp", 48 }, { 349, "Maraudon", 12201, "Princess Theradras", 51 },
    { 109, "Sunken Temple", 5709, "Shade of Eranikus", 55 }, { 230, "Blackrock Depths", 9019, "Emperor Dagran Thaurissan", 58 },
    { 229, "Lower Blackrock Spire", 9568, "Overlord Wyrmthalak", 60 }, { 229, "Upper Blackrock Spire", 10363, "General Drakkisath", 60 },
    { 429, "Dire Maul East", 11492, "Alzzin the Wildshaper", 58 }, { 429, "Dire Maul West", 11486, "Prince Tortheldrin", 60 },
    { 429, "Dire Maul North", 11501, "King Gordok", 60 }, { 329, "Stratholme Undead", 10440, "Baron Rivendare", 60 },
    { 329, "Stratholme Live", 10813, "Balnazzar", 60 }, { 289, "Scholomance", 1853, "Darkmaster Gandling", 60 },
}
one(T6, "boss1", "First Boss", "Defeat your first dungeon boss", "INV_Misc_Key_03", 2, function(b)
    if b.firsts and b.firsts.boss then return 1 end
    for _, d in ipairs(b.dungeons or {}) do if next(d.boss or {}) then return 1 end end
    return 0
end)
one(T6, "fullhouse", "Full House", "Defeat a dungeon boss with at least 3 dads", "Spell_Holy_PrayerOfSpirit", 3, function(b)
    for _, d in ipairs(b.dungeons or {}) do
        for _, k in pairs(d.boss or {}) do if (k.dads or 0) >= 3 then return 1 end end
    end
    return 0
end)
one(T6, "again", "Repeat Offender", "Enter the same dungeon 3 times", "INV_Misc_Key_04", 2, function(b)
    local per, best = {}, 0
    for _, d in ipairs(b.dungeons or {}) do
        per[d.id] = (per[d.id] or 0) + 1
        if per[d.id] > best then best = per[d.id] end
    end
    return best
end, 3)
for i, e in ipairs(L.BOSSES) do
    local npc = e[3]
    local c = one(T6, "dg" .. i, e[2], "Defeat " .. e[4], "INV_Misc_Bone_HumanSkull_01", e[5] <= 30 and 3 or 4, function(b)
        return yes(b.kills.npc[npc])
    end)
    c.npc = npc
end

-- PvP
local T7 = "pvp"
one(T7, "pvp1", "First Blood", "Defeat an enemy player", "Ability_DualWield", 2, function(b) return b.pvp.n or 0 end)
tiers(T7, "pvp", "War Veteran", "Defeat %s enemy players", "INV_Sword_27", { 10, 50, 200, 500 }, function(b) return b.pvp.n or 0 end)
one(T7, "classes", "Class Book", "Defeat every class of the enemy faction", "INV_Misc_Book_07", 4, function(b) return count(b.pvp.class) end, 8)
one(T7, "races", "Ethnology", "Defeat every race of the enemy faction", "Spell_Shadow_Charm", 3, function(b) return count(b.pvp.race) end, 4)
one(T7, "goliath", "David and Goliath", "Defeat an orange or red enemy player", "Ability_Rogue_Ambush", 4, function(b)
    local c = b.pvp.color or {}
    return (c.orange or 0) + (c.red or 0) + (c.skull or 0)
end)
one(T7, "revenge", "Sweet Revenge", "Defeat a player who killed you before", "Ability_Warrior_Revenge", 3, function(b)
    local by = b.pvp.killedBy and b.pvp.killedBy.players or {}
    for g, v in pairs(b.pvp.victims or {}) do
        local k = by[g]
        if k and v.t and k.t and v.t > k.t then return 1 end
        if k and (v.n or 0) >= 1 and not (v.t and k.t) then return 1 end
    end
    return 0
end)
one(T7, "victim", "Favourite Victim", "Defeat the same player 3 times", "Ability_Rogue_Eviscerate", 2, function(b)
    local best = 0
    for _, v in pairs(b.pvp.victims or {}) do if (v.n or 0) > best then best = v.n end end
    return best
end, 3)

-- Feats
local T8 = "feats"
one(T8, "epic", "Epic!", "Loot your first epic item", "INV_Misc_Gem_Amethyst_01", 4, function(b) return yes(b.firsts and b.firsts.epic) end)
tiers(T8, "nodeath", "Invulnerable", "Play %s evenings without dying (30 minutes or more)", "Spell_Holy_DivineIntervention", { 1, 3, 10, 25 }, function(b)
    local n = 0
    for _, d in pairs(b.days or {}) do if (d.s or 0) >= 1800 and (d.d or 0) == 0 then n = n + 1 end end
    return n
end)
one(T8, "ironwill", "Iron Will", "Gain 10 levels in a row without dying", "Ability_Warrior_DefensiveStance", 4, function(b)
    local lv = b.levels or {}
    for l = 11, L.MAX_LEVEL do
        local a, c = lv[l - 10], lv[l]
        if a and c and a.deaths and c.deaths and a.deaths == c.deaths then return 1 end
    end
    return 0
end)
one(T8, "immortal", "Immortal", "Reach level 60 without a single death", "Spell_Nature_Reincarnation", 5, function(b, ctx)
    return yes(ctx.level >= L.MAX_LEVEL and #(b.deaths or {}) == 0 and b.since and b.since.lvl <= 1)
end)
one(T8, "record", "Record Evening", "Defeat 300 foes in one day", "Ability_Rogue_SliceDice", 3, function(b) return b.records.bestDayKills or 0 end, 300)
tiers(T8, "collect", "Collector's Passion", "Own %s cards", "INV_Misc_Book_06", { 25, 50, 75, 100 }, function(_, ctx) return ctx.owned or 0 end)

-- Mishaps
local T9 = "mishaps"
tiers(T9, "fall", "Free Fall", "Fall to your death %s times", "Spell_Magic_FeatherFall", { 1, 5, 15 }, function(b) return deathsBy(b, "fall") end)
one(T9, "drown", "Deep Sea Diver", "Drown", "Spell_Frost_FrostShock", 2, function(b) return deathsBy(b, "drown") end)
one(T9, "lava", "Grill Master", "Die in lava", "Spell_Fire_Volcano", 3, function(b) return deathsBy(b, "lava") end)
one(T9, "gray", "How Embarrassing", "Get killed by a gray foe", "INV_Misc_Bone_HumanSkull_01", 3, function(b)
    local n = 0
    for _, d in ipairs(b.deaths or {}) do if d.c == "gray" then n = n + 1 end end
    return n
end)
tiers(T9, "deaths", "Spirit Healer's Regular", "Die %s times", "Spell_Shadow_DeathCoil", { 10, 25, 50, 100 }, function(b) return #(b.deaths or {}) end)
one(T9, "feud", "Old Feud", "Get killed by the same foe 3 times", "Spell_Shadow_UnholyFrenzy", 2, function(b)
    local per, best = {}, 0
    for _, d in ipairs(b.deaths or {}) do
        if d.why == "npc" and d.id then per[d.id] = (per[d.id] or 0) + 1; if per[d.id] > best then best = per[d.id] end end
    end
    return best
end, 3)
tiers(T9, "repair", "Money Pit", "Spend %s gold on repairs", "INV_Misc_Coin_05", { 10, 50, 100 }, function(b) return math.floor((b.money.repair or 0) / 10000) end)
one(T9, "afk", "Gone for a Bit", "Be away for 5 hours in total", "Spell_Nature_Sleep", 3, function(b) return b.afk or 0 end, 5 * 3600)

-- Summary
one("summary", "journey", "The Journey", "Reach level 60 and look back", "INV_Misc_Map_01", 5, lvl, 60)

----------------------------------------------------------------------
-- Evaluation
----------------------------------------------------------------------
function L:Quality(c, tier)
    if c.tiers then return math.min(5, c.start + math.max(tier or 1, 1) - 1) end
    return c.q
end
function L:Goal(c, tier)
    if not c.tiers then return c.text end
    local n = c.tiers[math.min(math.max(tier or 1, 1), #c.tiers)]
    local s = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (c.text:gsub("%%s", s))
end
function L:Need(c, tier)
    if c.tiers then return c.tiers[math.min(math.max(tier or 1, 1), #c.tiers)] end
    return c.need
end
function L:MaxTier(c) return c.tiers and #c.tiers or 1 end

-- the tier a value reaches (0 = none)
local function reached(c, v)
    if not num(v) then return 0 end
    if not c.tiers then return v >= c.need and 1 or 0 end
    local t = 0
    for i, need in ipairs(c.tiers) do if v >= need then t = i end end
    return t
end
L._Reached = reached

local function context(b)
    local ctx = { level = UnitLevel and call(UnitLevel, "player") or 1 }
    if not num(ctx.level) then ctx.level = 1 end
    local f = UnitFactionGroup and call(UnitFactionGroup, "player")
    ctx.faction = ok(f) and f or nil
    ctx.prof = OMQ.Tally.ProfSnapshot and call(OMQ.Tally.ProfSnapshot) or nil
    local owned = 0
    for _ in pairs(b.cards or {}) do owned = owned + 1 end
    ctx.owned = owned
    return ctx
end

-- value and tier of every entry, without changing anything
function L:Evaluate(b)
    b = b or (OMQ.Tally and OMQ.Tally.Book())
    if not b then return nil end
    local ctx = context(b)
    local out = {}
    for _, c in ipairs(self.CARDS) do
        local fine, v, label = pcall(c.value, b, ctx)
        if not fine then note("err." .. c.id); v = 0 end
        out[c.id] = { v = num(v) and v or 0, tier = reached(c, v), label = label }
    end
    return out, ctx
end

function L:Book() return OMQ.Tally and OMQ.Tally.Book() end
function L:Open(b)
    b = b or self:Book()
    return b and b.tabs and next(b.tabs) ~= nil or false
end
function L:Card(id) return self.byId[id] end
function L:Owned(id)
    local b = self:Book()
    local r = b and b.cards and b.cards[id]
    return type(r) == "table" and r or nil
end
function L:Seen(id)
    local b = self:Book()
    return b and b.seen and b.seen[id] or nil
end
function L:TabOpen(tab)
    local b = self:Book()
    return b and b.tabs and b.tabs[tab] ~= nil or false
end
function L:TabCards(tab)
    local out = {}
    for _, c in ipairs(self.CARDS) do if c.tab == tab then out[#out + 1] = c end end
    return out
end

local function groupDads()
    local names = {}
    local mates = OMQ.Tally.Mates and OMQ.Tally.Mates() or {}
    for g in pairs(mates) do
        local u = OMQ.users and OMQ.users[g]
        if u and u.name then names[#names + 1] = u.name end
    end
    table.sort(names)
    return table.concat(names, ", ")
end

-- grants what was reached; returns the new entries { {card, tier}, ... } and the tabs that opened
function L:Check()
    local b = self:Book()
    if not b then return nil end
    local level = UnitLevel and call(UnitLevel, "player")
    if not num(level) or level < self.MIN_LEVEL then return nil end
    b.cards = b.cards or {}
    b.tabs = b.tabs or {}
    local first = next(b.tabs) == nil
    local fresh, tabs = {}, {}
    for pass = 1, 2 do
        local res = self:Evaluate(b)
        for _, c in ipairs(self.CARDS) do
            local r = res[c.id]
            local old = b.cards[c.id]
            local oldTier = type(old) == "table" and old.n or 0
            -- the collection entry counts the others, so it goes in the second pass
            if r.tier > oldTier and ((c.id == "collect") == (pass == 2)) then
                local map = C_Map and call(C_Map.GetBestMapForUnit, "player")
                b.cards[c.id] = { n = r.tier, t = time(), l = level, m = num(map) and map or nil, g = groupDads(), x = r.label }
                fresh[#fresh + 1] = { card = c, tier = r.tier }
                note("new")
            end
        end
    end
    for _, tab in ipairs(self.TABS) do
        if not b.tabs[tab.id] then
            local open = tab.id == "summary" and level >= self.MAX_LEVEL
            if not open then
                for _, c in ipairs(self:TabCards(tab.id)) do if b.cards[c.id] then open = true; break end end
            end
            if open then b.tabs[tab.id] = time(); tabs[#tabs + 1] = tab.id end
        end
    end
    if #fresh > 0 or #tabs > 0 then OMQ:Fire("LEDGER_NEW", fresh, tabs, first and next(b.tabs) ~= nil) end
    return fresh, tabs
end

function L:SafeCheck()
    local fine, err = pcall(self.Check, self)
    if not fine then note("err.check"); OMQ:Error("ledger check", err) end
end

-- remembers a card someone else showed (only when it is not mine)
function L:MarkSeen(id, by, tier)
    local b = self:Book()
    if not b or not self.byId[id] then return end
    if b.cards and b.cards[id] then return end
    b.seen = b.seen or {}
    b.seen[id] = { by = by, n = tier, t = time() }
end

-- counts for the window header: owned in a tab / total
function L:Counts(tab)
    local b = self:Book()
    local own, all = 0, 0
    for _, c in ipairs(self.CARDS) do
        if not tab or c.tab == tab then
            all = all + 1
            if b and b.cards and b.cards[c.id] then own = own + 1 end
        end
    end
    return own, all
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event)
    if not L.ready then return end
    -- the counters book the level first; check a moment later
    C_Timer.After(event == "PLAYER_LEVEL_UP" and 2 or 1, function() L:SafeCheck() end)
end)

OMQ:On("READY", function()
    L.ready = true
    C_Timer.After(5, function() L:SafeCheck() end)
    C_Timer.NewTicker(CHECK_EVERY, function()
        if InCombatLockdown and InCombatLockdown() then return end
        L:SafeCheck()
    end)
end)
