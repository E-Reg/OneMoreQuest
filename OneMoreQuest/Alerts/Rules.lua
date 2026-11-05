-- One More Quest: alert rules (section 5)
-- Every rule returns the list of problems that exist right now, or "keep" when
-- the data cannot be read at the moment (the manager then keeps what it shows).
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local M = OMQ.Alerts

local GREEN  = { 0.49, 0.78, 0.44 }
local BLUE   = { 0.35, 0.65, 0.91 }
local ORANGE = { 0.91, 0.66, 0.24 }
local PURPLE = { 0.66, 0.55, 0.91 }
local TEAL   = { 0.31, 0.72, 0.79 }
local PINK   = { 0.90, 0.54, 0.72 }
local GOLD   = { 0.89, 0.71, 0.29 }
local RUST   = { 0.88, 0.50, 0.29 }

local REPAIR_BELOW = 30         -- percent durability
local DRINK_BELOW = 30          -- percent mana
local DRINK_DELAY = 3           -- seconds out of combat first
local AMMO_BELOW = 200
local BUFF_RANGE = 40           -- yards, when a position is known

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function isSecret(v) return issecretvalue and issecretvalue(v) end

local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

local function spellIcon(id)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    if GetSpellInfo then return select(3, GetSpellInfo(id)) end
end

local function knows(id)
    if IsPlayerSpell then return IsPlayerSpell(id) end
    if IsSpellKnown then return IsSpellKnown(id) end
    return false
end

local function knowsAny(list)
    for _, id in ipairs(list) do if knows(id) then return id end end
end

-- All learned ranks of a spell, by name: { {rank=, spellID=, sub=}, ... } sorted ascending.
local function learnedRanks(name)
    local SB = C_SpellBook
    if not (name and SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo) then
        return nil
    end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    local out, seen = {}, {}
    for line = 1, SB.GetNumSpellBookSkillLines() do
        local info = SB.GetSpellBookSkillLineInfo(line)
        if info then
            for i = 1, info.numSpellBookItems or 0 do
                local item = SB.GetSpellBookItemInfo((info.itemIndexOffset or 0) + i, bank)
                if item and (spellType == nil or item.itemType == spellType) and not item.isPassive
                    and not item.isOffSpec and item.spellID and not seen[item.spellID]
                    and (item.name or spellName(item.spellID)) == name then
                    local sub = item.subName
                    if (sub == nil or sub == "") and C_Spell and C_Spell.GetSpellSubtext then
                        sub = C_Spell.GetSpellSubtext(item.spellID)
                    end
                    local rank = type(sub) == "string" and tonumber(sub:match("%d+"))
                    if rank then
                        seen[item.spellID] = true
                        out[#out + 1] = { rank = rank, spellID = item.spellID, sub = sub }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.rank < b.rank end)
    return out
end

local function learnLevel(id)
    local v
    if C_Spell and C_Spell.GetSpellLevelLearned then v = C_Spell.GetSpellLevelLearned(id)
    elseif GetSpellLevelLearned then v = GetSpellLevelLearned(id) end
    if type(v) == "number" and not isSecret(v) then return v end
end

-- What to cast on a group member. A rank cannot be cast on a target more than 10 levels
-- below the level the rank was learned at; the action bar then picks a lower rank, a plain
-- name does not. So for a low level target we name the highest rank that still works.
local function castFor(castId, unit)
    local name = spellName(castId)
    if not name or unit == "player" then return name end
    local lvl = UnitLevel and UnitLevel(unit)
    if type(lvl) ~= "number" or isSecret(lvl) or lvl <= 0 then return name end
    local ranks = learnedRanks(name)
    if not ranks or #ranks < 2 then return name end
    local pick
    for _, r in ipairs(ranks) do
        local need = learnLevel(r.spellID)
        if need and need - 10 <= lvl then pick = r end
    end
    pick = pick or ranks[1]
    if pick == ranks[#ranks] then return name end
    return name .. "(" .. pick.sub .. ")"
end

-- Names of the helpful auras on a unit, or nil when they cannot be read.
local function auraNames(unit)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    local names = {}
    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
        if not aura then break end
        local name = aura.name
        if isSecret(name) then return nil end
        if type(name) == "string" then names[name] = true end
    end
    return names
end

local function icon(path) return path end

----------------------------------------------------------------------
-- 1. Train skills: in a major city or near the own class trainer (decision 187)
----------------------------------------------------------------------
-- Levels come in bands of an even level and the next one (10 and 11). A band is done when the
-- player opened his class trainer at one of those levels, or dismissed the card. Until then the
-- card shows in a major city and whenever a trainer of his class is closer than NEAR_TRAINER yards.
local NEAR_TRAINER = 200
M.NEAR_TRAINER = NEAR_TRAINER

local function band(level) level = level or 1; return level - (level % 2) end
M.Band = band

local function trainDone(guid, lvl)
    local t = OMQ.db.alerts.trainDone
    return t and guid and t[guid] and t[guid][lvl]
end
M.TrainDone = trainDone

local function markTrained(lvl)
    local guid = UnitGUID("player")
    if not (lvl and guid) then return end
    local db = OMQ.db.alerts
    db.trainDone = db.trainDone or {}
    db.trainDone[guid] = db.trainDone[guid] or {}
    db.trainDone[guid][lvl] = true
end
M.MarkTrained = markTrained

-- the nearest fixed place of a kind (for trainers: of my class) and my faction on this map: name, yards
function M.NearestFixed(kind)
    if not (UnitPosition and OMQ.Guide and OMQ.Guide.WorldOf) then return nil end
    local a, b, _, inst = UnitPosition("player")
    if type(a) ~= "number" or isSecret(a) or isSecret(b) then return nil end
    local _, class = UnitClass("player")
    local fac = UnitFactionGroup and UnitFactionGroup("player")
    fac = (fac == "Alliance" and "A") or (fac == "Horde" and "H") or nil
    local bestName, best
    for _, p in ipairs(OMQ.fixedPlaces or {}) do
        if p[1] == kind and (kind ~= "trainer" or p[2] == class) and (not fac or p[6] == "AH" or p[6] == fac)
            and not (p[8] and (UnitLevel and tonumber((UnitLevel("player"))) or 0) > p[8]) then    -- decision 253
            local w = OMQ.Guide.WorldOf(p)
            if w and w[3] == inst then
                local d = math.sqrt((w[1] - a) ^ 2 + (w[2] - b) ^ 2)
                if not best or d < best then best, bestName = d, p[7] end
            end
        end
    end
    if bestName and OMQ.Guide.Title then bestName = OMQ.Guide.Title(bestName) end
    -- class trainers the player has used himself, also those missing from the data (decision 218)
    if kind == "trainer" and OMQ.Places then
        for _, r in ipairs(OMQ.Places:All("trainer")) do
            if r.cls == class and r.inst == inst and type(r.a) == "number" then
                local d = math.sqrt((r.a - a) ^ 2 + (r.b - b) ^ 2)
                if not best or d < best then best, bestName = d, r.name end
            end
        end
    end
    return bestName, best
end
function M.NearestClassTrainer() return M.NearestFixed("trainer") end

-- What the class trainer has for me (decision 237, Data/TrainerSpells.lua): every spell up to my
-- level that I do not know yet, for my race and faction, whose required spells I know or can learn
-- in the same visit (a talent spell I never took keeps its ranks out). Returns a list of
-- { id, cost, level } sorted by level, and the total cost; nil when the class has no data.
local RACE_ID = { Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5, Tauren = 6, Gnome = 7, Troll = 8 }
local function knowsSpell(id)
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    if IsSpellKnown and IsSpellKnown(id) then return true end
    return false
end
function M.NewAtTrainer(level, class)
    local _, myClass = UnitClass("player")
    local data = OMQ.TrainerSpells and OMQ.TrainerSpells[class or myClass]
    if not data then return nil end
    level = level or UnitLevel("player") or 1
    local _, raceFile, raceId
    if UnitRace then _, raceFile, raceId = UnitRace("player") end
    raceId = raceId or RACE_ID[raceFile or ""]
    local fac = UnitFactionGroup and UnitFactionGroup("player")
    fac = (fac == "Alliance" and "A") or (fac == "Horde" and "H") or nil
    local cand = {}
    for lvl, list in pairs(data) do
        if lvl <= level then
            for _, e in ipairs(list) do
                local id, cost, req, races, efac = e[1], e[2], e[3], e[4], e[5]
                local raceOk = true
                if races and raceId then
                    raceOk = false
                    for _, r in ipairs(races) do if r == raceId then raceOk = true end end
                end
                if raceOk and (not efac or not fac or efac == fac) and not knowsSpell(id) then
                    cand[id] = { id = id, cost = cost or 0, level = lvl, req = req }
                end
            end
        end
    end
    -- drop what needs a spell that is neither known nor learnable now (talents), until nothing changes
    local changed = true
    while changed do
        changed = false
        for id, c in pairs(cand) do
            for _, r in ipairs(c.req or {}) do
                if not knowsSpell(r) and not cand[r] then cand[id] = nil; changed = true; break end
            end
        end
    end
    local out, total = {}, 0
    for _, c in pairs(cand) do out[#out + 1] = c; total = total + c.cost end
    table.sort(out, function(a, b) if a.level ~= b.level then return a.level < b.level end return a.id < b.id end)
    return out, total
end

local function money(c)
    c = math.floor(c or 0)
    local g, s_, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "g" end
    if s_ > 0 then t[#t + 1] = s_ .. "s" end
    if k > 0 or #t == 0 then t[#t + 1] = k .. "c" end
    return table.concat(t, " ")
end
M.Money = money

-- "4 new: Renew, Mind Blast, Fade +1 - 12s" (or "you need 3s more") and the hover lines
function M.TrainerText(list, total)
    local names, seen = {}, {}
    for _, c in ipairs(list) do
        local n = spellName(c.id)
        if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    local shown = {}
    for i = 1, math.min(3, #names) do shown[i] = names[i] end
    local txt = #list .. " new: " .. table.concat(shown, ", ") .. (#names > 3 and (" +" .. (#names - 3)) or "")
    local have = GetMoney and GetMoney() or 0
    if total > have then
        txt = txt .. " - you need " .. money(total - have) .. " more"
    else
        txt = txt .. " - " .. money(total)
    end
    local tip = { "At your class trainer" }
    for _, c in ipairs(list) do
        local rank = C_Spell and C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(c.id)
        local n = (spellName(c.id) or ("Spell " .. c.id)) .. ((type(rank) == "string" and rank ~= "") and (" (" .. rank .. ")") or "")
        tip[#tip + 1] = { n, money(c.cost) }
    end
    tip[#tip + 1] = { "Total", money(total) }
    return txt, tip
end

-- a level up to an even level from 10: a card anywhere with what the trainer has (decision 237)
local function levelUpPending(guid)
    local t = OMQ.db.alerts.trainUp
    return t and guid and t[guid]
end
local lvlFrame = CreateFrame("Frame")
pcall(lvlFrame.RegisterEvent, lvlFrame, "PLAYER_LEVEL_UP")
lvlFrame:SetScript("OnEvent", function(_, _, newLevel)
    newLevel = tonumber(newLevel)
    local guid = UnitGUID("player")
    if not (newLevel and guid) or newLevel < 10 or newLevel % 2 ~= 0 then return end
    local db = OMQ.db.alerts
    db.trainUp = db.trainUp or {}
    db.trainUp[guid] = newLevel
    C_Timer.After(1, function() if OMQ.Alerts then OMQ.Alerts:Evaluate() end end)
end)

M:Register({
    id = "train", name = "Train new skills: after a level up, in a major city or near your class trainer",
    check = function()
        local level = UnitLevel("player") or 1
        local even = band(level)
        local guid = UnitGUID("player")
        if even < 2 or trainDone(guid, even) then return nil end
        local list, total = M.NewAtTrainer(level)
        if list and #list == 0 then return nil end          -- nothing new at the trainer
        local txt, tip
        if list then txt, tip = M.TrainerText(list, total) end
        -- right after the level up: everywhere, until dismissed or trained
        if levelUpPending(guid) == even then
            return { {
                key = "trainup:" .. even,
                text = "Level " .. even .. ": new at your class trainer",
                title = "Level " .. even .. ": new at your class trainer", sub = txt or "New skills to learn",
                tipLines = tip, go = "trainer", tag = "LEVEL UP",
                icon = "Interface\\Icons\\INV_Misc_Book_09", color = GREEN,
            } }
        end
        local where
        if OMQ:InMajorCity() then
            where = "Your class trainer is in this city"
        else
            local name, d = M.NearestClassTrainer()
            if not (d and d <= NEAR_TRAINER) then return nil end
            where = string.format("%s is %d yards away", name or "Your class trainer", math.floor(d))
        end
        return { {
            key = "train:" .. even,
            text = "Level " .. even .. ": train new skills",
            title = "Level " .. even .. ": train new skills", sub = txt or where,
            tipLines = tip and (function() local t = { tip[1], where }; for i = 2, #tip do t[#t + 1] = tip[i] end; return t end)(),
            go = "trainer",
            icon = "Interface\\Icons\\INV_Misc_Book_09", color = GREEN,
        } }
    end,
})

OMQ:On("ALERT_DISMISSED", function(key)
    local lvl = tonumber(tostring(key):match("^train:(%d+)$"))
    if lvl then markTrained(lvl) end
    -- the level-up card: gone; the city and trainer card still reminds (decision 237)
    if tostring(key):match("^trainup:") then
        local t, guid = OMQ.db.alerts.trainUp, UnitGUID("player")
        if t and guid then t[guid] = nil end
    end
end)

----------------------------------------------------------------------
-- 1b. Drinks: fewer than 10 in a major city or near an innkeeper (decision 189)
----------------------------------------------------------------------
local LOW_DRINKS, NEAR_INN = 10, 200
M.LOW_DRINKS, M.NEAR_INN = LOW_DRINKS, NEAR_INN
-- mages never buy water (decision 280): they conjure it. Conjure Water, rank 1 to 7
M.CONJURE_WATER = { 5504, 5505, 5506, 6127, 10138, 10139, 10140 }
local function conjureCard(n)
    if (IsMounted and IsMounted()) or (UnitOnTaxi and UnitOnTaxi("player")) then return nil end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return nil end
    local best
    for _, id in ipairs(M.CONJURE_WATER) do if knows(id) then best = id end end
    if not best then return nil end
    local name = spellName(best)
    if not name or isSecret(name) then return nil end
    local sub = string.format("%d left - a click conjures more", n)
    return { {
        key = "conjure", text = "Conjure water: " .. sub, title = "Conjure water", sub = sub, tag = "DRINKS",
        cast = name, unit = "player", icon = spellIcon(best) or "Interface\\Icons\\INV_Drink_06", color = { 0.35, 0.65, 0.91 },
    } }
end
M:Register({
    id = "drinks", name = "Out of Drinks",
    check = function()
        if InCombatLockdown() then return "keep" end
        local n = OMQ.Ready and OMQ.Ready.Drinks and OMQ.Ready.Drinks()
        if not n or n >= LOW_DRINKS then return nil end
        local _, class = UnitClass("player")
        if class == "MAGE" then return conjureCard(n) end          -- anywhere, never "buy drinks" (decision 280)
        local name, d = M.NearestFixed("inn")
        local sub
        if d and d <= NEAR_INN then
            sub = string.format("%d left - %s is %d yards away", n, name or "An innkeeper", math.floor(d))
        elseif OMQ:InMajorCity() then
            sub = string.format("%d left - the innkeeper sells drinks", n)
        else
            return nil
        end
        return { {
            key = "drinks", text = "Buy drinks: " .. sub, title = "Buy drinks", sub = sub, tag = "DRINKS",
            go = "inn", icon = "Interface\\Icons\\INV_Drink_07", color = { 0.35, 0.65, 0.91 },
        } }
    end,
})

-- opening the own class trainer ticks the band off (not a profession trainer)
local trainerFrame = CreateFrame("Frame")
pcall(trainerFrame.RegisterEvent, trainerFrame, "TRAINER_SHOW")
trainerFrame:SetScript("OnEvent", function()
    if IsTradeskillTrainer and IsTradeskillTrainer() then return end
    -- my class trainer by his title (decision 218), else by the data: within 30 yards of a known one
    local mine = OMQ.Places and OMQ.Places.IsMyClassTrainer and OMQ.Places.IsMyClassTrainer()
    if mine == false then return end         -- his title names another trade or class
    if mine == nil then
        local _, d = M.NearestClassTrainer()
        if d and d > 30 then return end      -- a weapon master or another trainer, not my class trainer
    end
    markTrained(band(UnitLevel("player")))
    if OMQ.Alerts then OMQ.Alerts:Evaluate() end
end)

----------------------------------------------------------------------
-- 2. Drink
----------------------------------------------------------------------
local leftCombatAt = 0
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function() leftCombatAt = GetTime() end)
function M.leftCombatAt() return leftCombatAt end

local drinkName
M:Register({
    id = "drink", name = "Drink when mana is below 30 percent",
    check = function()
        if InCombatLockdown() then return "keep" end
        if (GetTime() - leftCombatAt) < DRINK_DELAY then return nil end
        if UnitIsDeadOrGhost("player") or (IsMounted and IsMounted()) then return nil end
        local mana = Enum and Enum.PowerType and Enum.PowerType.Mana or 0
        local cur, max = UnitPower("player", mana), UnitPowerMax("player", mana)
        if isSecret(cur) or isSecret(max) then
            return nil        -- handled by the mana card (Alerts/ManaCard.lua)
        end
        if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
        local pct = cur / max * 100
        if pct >= DRINK_BELOW then return nil end
        drinkName = drinkName or spellName(430)
        local names = auraNames("player")
        if names and drinkName and names[drinkName] then return nil end     -- already drinking
        local best = OMQ.Ready and OMQ.Ready.BestDrink and OMQ.Ready.BestDrink()
        return { {
            key = "drink", text = string.format("Drink: mana at %d%%", math.floor(pct)),
            icon = "Interface\\Icons\\INV_Drink_07", color = BLUE,
            useItem = best and ("item:" .. best) or nil,          -- a click drinks (decision 219)
        } }
    end,
})

----------------------------------------------------------------------
-- 3. Repair
----------------------------------------------------------------------
M:Register({
    id = "repair", name = "Repair when the most damaged item is below 30 percent",
    check = function()
        local lowest, slot
        for s = 1, 19 do
            local cur, max = GetInventoryItemDurability(s)
            if type(cur) == "number" and type(max) == "number" and max > 0 then
                local pct = cur / max * 100
                if not lowest or pct < lowest then lowest, slot = pct, s end
            end
        end
        if lowest and lowest < REPAIR_BELOW then
            return { {
                key = "repair",
                text = string.format("Repair: most damaged item at %d%%", math.floor(lowest)),
                icon = GetInventoryItemTexture("player", slot) or "Interface\\Icons\\Trade_BlackSmithing",
                color = ORANGE, go = "repair",
            } }
        end
        -- leaving a major city below 60 percent (decision 239): one card, with the arrow back.
        -- Before a flight too (decision 306): near a flight master in a major city, or the flight map open.
        local leaving = M.leftCityAt and GetTime() - M.leftCityAt < M.LEAVE_CARD_SECONDS
        local flying = M.flightAt and GetTime() - M.flightAt < M.FLIGHT_CARD_SECONDS
        if lowest and lowest < M.LEAVE_REPAIR_BELOW and (leaving or flying) then
            local name, d = M.NearestFixed("repair")
            return { {
                key = "repair:leave",
                title = flying and not leaving and "Repair before you fly" or "Repair before you go", tag = "REPAIR",
                sub = string.format("Most damaged item at %d%%%s", math.floor(lowest),
                    d and string.format(" - %s is %d yards back", name or "a repair vendor", math.floor(d)) or ""),
                text = flying and not leaving and "Repair before you fly" or "Repair before you go",
                icon = GetInventoryItemTexture("player", slot) or "Interface\\Icons\\Trade_BlackSmithing",
                color = ORANGE, go = "repair",
            } }
        end
    end,
})

-- leaving a major city: remember the moment (decision 239)
M.LEAVE_REPAIR_BELOW, M.LEAVE_CARD_SECONDS = 60, 180
M.FLIGHT_NEAR, M.FLIGHT_CARD_SECONDS = 40, 30          -- decision 306: yards to the flight master, how long the card stays
local wasInCity = nil
function M.CityTick()
    local inCity = OMQ:InMajorCity() and true or false
    if wasInCity and not inCity then
        M.leftCityAt = GetTime()
        if M.Evaluate then M:Evaluate() end
    elseif inCity then
        M.leftCityAt = nil
        -- walking up to the flight master of the city (decision 306)
        local _, d = M.NearestFixed("flight")
        if d and d <= M.FLIGHT_NEAR then
            local fresh = not (M.flightAt and GetTime() - M.flightAt < M.FLIGHT_CARD_SECONDS)
            M.flightAt = GetTime()
            if fresh and M.Evaluate then M:Evaluate() end
        end
    end
    wasInCity = inCity
end
-- the flight map is open (any flight master): last chance to repair (decision 306)
local taxiFrame = CreateFrame("Frame")
pcall(taxiFrame.RegisterEvent, taxiFrame, "TAXIMAP_OPENED")
taxiFrame:SetScript("OnEvent", function()
    M.flightAt = GetTime()
    if M.Evaluate then pcall(M.Evaluate, M) end
end)
local cityFrame = CreateFrame("Frame")
local cityAcc = 0
cityFrame:SetScript("OnUpdate", function(_, elapsed)
    cityAcc = cityAcc + (elapsed or 0)
    if cityAcc < 2 then return end
    cityAcc = 0
    pcall(M.CityTick)
end)

----------------------------------------------------------------------
-- 4. Missing spell rank
-- A ranked spell counts as covered when its name is on an action bar (the game
-- moves the button to the new rank). With db.alerts.strictRank the highest
-- rank itself has to be on a bar.
----------------------------------------------------------------------
local rankCache, rankCacheAt, rankDirty = nil, 0, true
local rankFrame = CreateFrame("Frame")
for _, e in ipairs({ "SPELLS_CHANGED", "ACTIONBAR_SLOT_CHANGED", "PLAYER_LEVEL_UP",
                    "UPDATE_BONUS_ACTIONBAR", "ACTIONBAR_PAGE_CHANGED" }) do
    pcall(rankFrame.RegisterEvent, rankFrame, e)
end
rankFrame:SetScript("OnEvent", function() rankDirty = true end)

local function highestRanks()
    local SB = C_SpellBook
    if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo) then
        return nil
    end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    local best = {}
    for line = 1, SB.GetNumSpellBookSkillLines() do
        local info = SB.GetSpellBookSkillLineInfo(line)
        if info then
            for i = 1, info.numSpellBookItems or 0 do
                local item = SB.GetSpellBookItemInfo((info.itemIndexOffset or 0) + i, bank)
                if item and (spellType == nil or item.itemType == spellType) and not item.isPassive
                    and not item.isOffSpec and item.spellID then
                    local sub = item.subName
                    if (sub == nil or sub == "") and C_Spell and C_Spell.GetSpellSubtext then
                        sub = C_Spell.GetSpellSubtext(item.spellID)
                    end
                    local rank = type(sub) == "string" and tonumber(sub:match("%d+"))
                    local name = item.name or spellName(item.spellID)
                    if rank and name and (not best[name] or rank > best[name].rank) then
                        best[name] = { name = name, rank = rank, spellID = item.spellID }
                    end
                end
            end
        end
    end
    return best
end

-- the first slot of the main bar page the player sees right now (decision 403): a warrior's stance
-- (also a druid's form or a rogue's stealth) swaps the main bar to its own page 73-120 (bonus bar),
-- a paged main bar shows another page; slots 1-12 are then not on screen
function M.MainBarBase()
    local btn = _G.ActionButton1
    local a = btn and btn.action
    if type(a) == "number" and a >= 1 and a <= 120 then return math.floor((a - 1) / 12) * 12 end
    local page = (GetActionBarPage and GetActionBarPage()) or 1
    local offset = (GetBonusBarOffset and GetBonusBarOffset()) or 0
    if page == 1 and offset > 0 then return ((NUM_ACTIONBAR_PAGES or 6) + offset - 1) * 12 end
    return (page - 1) * 12
end
-- a warrior is always in a stance once he has learned one: his plain main page 1-12 is never shown,
-- so a spell lying there (the game puts new spells there) is not on a bar for him (decision 403)
local function hiddenPlainPage()
    local _, class = UnitClass("player")
    return class == "WARRIOR" and ((GetBonusBarOffset and GetBonusBarOffset()) or 0) > 0
end
M._hiddenPlainPage = hiddenPlainPage

local function barSpells()
    local names, ids = {}, {}
    local from = hiddenPlainPage() and 13 or 1
    for slot = from, 120 do
        local kind, id = GetActionInfo(slot)
        if kind == "macro" and GetMacroSpell then
            local sid = GetMacroSpell(id)
            if sid then kind, id = "spell", sid end
        end
        if kind == "spell" and id then
            ids[id] = true
            local n = spellName(id)
            if n then names[n] = true end
        end
    end
    return names, ids
end

-- spells bound in WoW Forever's click casting (decision 225): a binding holds the base spell
-- and casts it from unit frames, so such a spell needs no action bar slot (any rank)
local function clickBoundNames()
    local names = {}
    local CB = C_ClickBindings
    if not (CB and CB.GetProfileInfo) then return names end
    local ok, profile = pcall(CB.GetProfileInfo)
    if not ok or type(profile) ~= "table" then return names end
    local T = Enum and Enum.ClickBindingType or {}
    for _, info in ipairs(profile) do
        local id = info.actionID
        if info.type == (T.Macro or 2) and GetMacroSpell then id = GetMacroSpell(id)
        elseif info.type ~= (T.Spell or 1) then id = nil end
        local n = id and spellName(id)
        if n then names[n] = true end
    end
    return names
end
M._clickBoundNames = clickBoundNames

-- /omq clicks: what the game's click casting holds and how it encodes modifier keys (decision 225),
-- the groundwork for binding Shift-clicks with heals later; reads only, changes nothing
OMQ:RegisterCommand("clicks", function()
    local CB = C_ClickBindings
    OMQ:Print("click casting: C_ClickBindings " .. (CB and "yes" or "MISSING") ..
        ", SetProfileByInfo " .. tostring(CB and CB.SetProfileByInfo ~= nil) ..
        ", CanSpellBeClickBound " .. tostring(CB and CB.CanSpellBeClickBound ~= nil) ..
        ", GetStringFromModifiers " .. tostring(GetStringFromModifiers ~= nil))
    if not (CB and CB.GetProfileInfo) then return end
    local ok, profile = pcall(CB.GetProfileInfo)
    if not ok then print("  GetProfileInfo failed: " .. tostring(profile)); return end
    for i, info in ipairs(profile or {}) do
        local what = tostring(info.actionID)
        if info.type == 1 or info.type == 4 then what = (spellName(info.actionID) or "?") .. " (" .. what .. ")" end
        local mods = GetStringFromModifiers and select(2, pcall(GetStringFromModifiers, info.modifiers or 0)) or "?"
        print(string.format("  %d: type %s, %s, button %s, modifiers %s = \"%s\"", i, tostring(info.type), what,
            tostring(info.button), tostring(info.modifiers), tostring(mods)))
    end
    if GetStringFromModifiers then
        local bits = {}
        for b = 0, 11 do
            local okb, str = pcall(GetStringFromModifiers, 2 ^ b)
            if okb and str and str ~= "" then bits[#bits + 1] = (2 ^ b) .. "=" .. str end
        end
        print("  modifier bits: " .. table.concat(bits, ", "))
    end
end, "show the click casting bindings (read only)")

-- "place it" (decision 240): a click puts the spells on the first free slots of the shown bars
M.BAR_SLOTS = {
    { main = true },                                                -- main bar, always: the page on screen
    { from = 61, to = 72, frame = "MultiBarBottomLeft" },
    { from = 49, to = 60, frame = "MultiBarBottomRight" },
    { from = 25, to = 36, frame = "MultiBarRight" },
    { from = 37, to = 48, frame = "MultiBarLeft" },
}
function M.FreeSlots()
    local out, seen = {}, {}
    if not HasAction then return out end
    for _, bar in ipairs(M.BAR_SLOTS) do
        local f = bar.frame and _G[bar.frame]
        local from, to = bar.from, bar.to
        if bar.main then from = M.MainBarBase() + 1; to = from + 11 end
        if not bar.frame or (f and f.IsShown and f:IsShown()) then
            for slot = from, to do
                local ok, has = pcall(HasAction, slot)
                if ok and not has and not seen[slot] then out[#out + 1] = slot; seen[slot] = true end
            end
        end
    end
    return out
end
function M.PlaceSpells(ids)
    if InCombatLockdown() then return 0 end
    local pick = (C_Spell and C_Spell.PickupSpell) or PickupSpell
    if not (pick and PlaceAction) then
        OMQ:Print("Could not place the spell: the game offers no way for addons here - drag it from your spellbook")
        return 0
    end
    local free = M.FreeSlots()
    local placed = 0
    for _, id in ipairs(ids) do
        local slot = free[placed + 1]
        if not slot then
            OMQ:Print("No free slot on your shown action bars - drag the spell from your spellbook")
            break
        end
        local ok = pcall(pick, id)
        if ok and GetCursorInfo and GetCursorInfo() then
            pcall(PlaceAction, slot)
            placed = placed + 1
        end
        if ClearCursor then ClearCursor() end
    end
    if placed == 0 and #ids > 0 and #free > 0 then
        OMQ:Print("Could not place the spell - drag it from your spellbook")
    end
    rankDirty = true
    return placed
end

M:Register({
    id = "rank", name = "Learned spell ranks that are not on an action bar",
    check = function()
        if InCombatLockdown() then return "keep" end
        if not rankDirty and rankCache and (GetTime() - rankCacheAt) < 10 then return rankCache end
        local best = highestRanks()
        if not best then
            M.unavailable = M.unavailable or {}
            M.unavailable.rank = "spellbook API not available"
            return nil
        end
        local names, ids = barSpells()
        local clicked = clickBoundNames()
        local strict = not OMQ.db.alerts.lenientRank     -- the highest learned rank itself must be on a bar
        local missing = {}
        for name, s in pairs(best) do
            local covered = clicked[name] or (strict and ids[s.spellID]) or (not strict and names[name])
            if not covered then missing[#missing + 1] = s end
        end
        table.sort(missing, function(a, b) return a.name < b.name end)
        local result = {}
        if #missing > 3 then
            local ids = {}
            for _, m in ipairs(missing) do ids[#ids + 1] = m.spellID end
            result[1] = {
                key = "rank:many", text = #missing .. " spells are not on a bar",
                title = #missing .. " spells are not on a bar", sub = "Click: put them on your action bars",
                icon = "Interface\\Icons\\INV_Misc_Book_11", color = PURPLE,
                open = function() M.PlaceSpells(ids); return "keep" end,
            }
        else
            for _, s in ipairs(missing) do
                local id = s.spellID
                result[#result + 1] = {
                    key = "rank:" .. s.name .. ":" .. s.rank,
                    text = s.name .. " " .. s.rank .. " is not on a bar",
                    title = s.name .. " " .. s.rank .. " is not on a bar", sub = "Click: put it on your action bar",
                    icon = spellIcon(s.spellID), color = PURPLE,
                    open = function() M.PlaceSpells({ id }); return "keep" end,
                }
            end
        end
        rankCache, rankCacheAt, rankDirty = result, GetTime(), false
        return result
    end,
})

----------------------------------------------------------------------
-- 5. Profession training: skill 50 / 125 / 200 in a major city
----------------------------------------------------------------------
local STEPS = {
    { cap = 75,  at = 50,  level = 10, rank = "Journeyman" },
    { cap = 150, at = 125, level = 20, rank = "Expert" },
    { cap = 225, at = 200, level = 35, rank = "Artisan" },
}

local function professionLines()
    -- modern API: GetProfessions() -> indices, GetProfessionInfo(index)
    if GetProfessions and GetProfessionInfo then
        local lines = {}
        for _, idx in pairs({ GetProfessions() }) do
            if idx then
                local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(idx)
                if name and type(rank) == "number" and type(maxRank) == "number" then
                    lines[#lines + 1] = { name = name, rank = rank, max = maxRank,
                                          key = OMQ.Guide and OMQ.Guide.ProfKey(skillLine, name) }
                end
            end
        end
        if #lines > 0 then return lines end
    end
    if not (GetNumSkillLines and GetSkillLineInfo) then return nil end
    local lines = {}
    local inProfessions = false
    local trade = _G.TRADE_SKILLS or "Professions"
    local secondary = _G.SECONDARY_SKILLS or "Secondary Skills"
    for i = 1, GetNumSkillLines() do
        local name, header, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        if header then
            inProfessions = (name == trade or name == secondary)
        elseif inProfessions and name and type(rank) == "number" and type(maxRank) == "number" then
            lines[#lines + 1] = { name = name, rank = rank, max = maxRank,
                                  key = OMQ.Guide and OMQ.Guide.ProfKey(nil, name) }
        end
    end
    return lines
end

M.ProfessionLines = professionLines

M:Register({
    id = "prof", name = "Train a profession level in a major city",
    check = function()
        if not OMQ:InMajorCity() then return nil end
        local lines = professionLines()
        if not lines then
            M.unavailable = M.unavailable or {}
            M.unavailable.prof = "skill API not available"
            return nil
        end
        local level = UnitLevel("player") or 1
        local result = {}
        for _, l in ipairs(lines) do
            for _, step in ipairs(STEPS) do
                if l.max == step.cap and l.rank >= step.at and level >= step.level then
                    result[#result + 1] = {
                        key = "prof:" .. l.name .. ":" .. step.cap,
                        text = l.name .. ": train " .. step.rank,
                        icon = "Interface\\Icons\\INV_Misc_Gear_01", color = TEAL,
                        go = l.key and ("proftrainer:" .. l.key) or nil,
                    }
                end
            end
        end
        return result
    end,
})

----------------------------------------------------------------------
-- 5b. Profession tools (decision 236): a profession that needs a tool, and the tool is neither in
-- the bags nor in the bank (nor equipped, for the fishing pole). A click leads the arrow to the
-- nearest vendor that sells it (Data/ToolVendors.lua). Mostly trade goods vendors and the
-- profession's supply vendor; Flint and Tinder is sold by general goods vendors.
----------------------------------------------------------------------
M.TOOLS = {
    Blacksmithing = { { item = 5956, name = "Blacksmith Hammer" } },
    Engineering   = { { item = 5956, name = "Blacksmith Hammer" } },
    Mining        = { { item = 2901, name = "Mining Pick" } },
    Skinning      = { { item = 7005, name = "Skinning Knife" } },
    Fishing       = { { item = 6256, name = "Fishing Pole",
                        also = { 6365, 6366, 6367, 12225, 19022, 19970 } } },     -- any fishing pole counts
    Enchanting    = { { item = 6217, name = "Copper Rod",                         -- for the Runed Copper Rod
                        also = { 6218, 6339, 11130, 11145, 16207 } } },           -- any enchanting rod counts
    Cooking       = { { item = 4471, name = "Flint and Tinder" } },              -- for the Basic Campfire
}

local function itemCount(id)
    if C_Item and C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, id, true)
        if ok and type(n) == "number" then return n end
    end
    if GetItemCount then
        local ok, n = pcall(GetItemCount, id, true)
        if ok and type(n) == "number" then return n end
    end
    return nil                                  -- unknown: no card
end

local function equipped(id)
    local fn = GetInventoryItemID
    if not fn then return false end
    for _, slot in ipairs({ 16, 17, 18 }) do
        local ok, have = pcall(fn, "player", slot)
        if ok and have == id then return true end
    end
    return false
end

function M.HasTool(tool)
    local any = false
    for _, id in ipairs({ tool.item, unpack(tool.also or {}) }) do
        local n = itemCount(id)
        if n == nil then return true end        -- the game does not answer: assume yes
        if n > 0 or equipped(id) then any = true; break end
    end
    return any
end

local function toolName(tool)
    local n
    if C_Item and C_Item.GetItemNameByID then n = C_Item.GetItemNameByID(tool.item) end
    if (not n or isSecret(n)) and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, tool.item)
    end
    return (type(n) == "string" and not isSecret(n)) and n or tool.name
end
M.ToolName = toolName

local function toolIcon(tool)
    if C_Item and C_Item.GetItemIconByID then
        local ok, ic = pcall(C_Item.GetItemIconByID, tool.item)
        if ok and ic then return ic end
    end
    return "Interface\\Icons\\INV_Misc_Bag_10"
end

M:Register({
    id = "tools", name = "Buy the tool of a profession",
    check = function()
        local lines = professionLines()
        if not lines then return nil end
        local out, seen = {}, {}
        for _, l in ipairs(lines) do
            for _, tool in ipairs(M.TOOLS[l.key or ""] or {}) do
                if not seen[tool.item] and not M.HasTool(tool) then
                    seen[tool.item] = true
                    out[#out + 1] = {
                        key = "tool:" .. tool.item,
                        text = "Buy " .. toolName(tool) .. " (" .. (l.name or l.key) .. ")",
                        icon = toolIcon(tool), color = ORANGE,
                        go = "tool:" .. tool.item,                 -- click: arrow to the nearest seller
                    }
                end
            end
        end
        return out
    end,
})

----------------------------------------------------------------------
-- 5c. Profession tracking (decision 329): Mining teaches Find Minerals, Herbalism teaches Find Herbs. While none of
-- the trackings of my professions is on, a card offers it; a left click casts it. Only one tracking can run at a
-- time, so with both professions one cast takes both cards away.
----------------------------------------------------------------------
M.TRACKING = {
    { key = "Mining",    spell = 2580, what = "ore" },
    { key = "Herbalism", spell = 2383, what = "herbs" },
}

-- Is the tracking with this spell on? true / false, or nil when the game gives no answer.
-- Sources, in this order: the tracking list of the minimap, the active tracking icon, the auras.
function M.TrackingOn(spellId)
    local name = spellName(spellId)
    local answered = false
    -- 1. the list of tracking types (modern table answer or the classic list of values)
    if C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo then
        local okN, n = pcall(C_Minimap.GetNumTrackingTypes)
        if okN and type(n) == "number" and n > 0 then
            for i = 1, n do
                local ok, a, b, c = pcall(C_Minimap.GetTrackingInfo, i)
                if ok then
                    local tname, active, sid
                    if type(a) == "table" then tname, active, sid = a.name, a.active, a.spellID
                    else tname, active = a, c end
                    if not isSecret(tname) and not isSecret(active) then
                        answered = true
                        if (sid == spellId or (name and tname == name)) and active then return true end
                    end
                end
            end
        end
    end
    -- 2. the icon of the tracking that is on
    local tex
    if GetTrackingTexture then
        local ok, t = pcall(GetTrackingTexture)
        if ok and not isSecret(t) then
            if t == nil then return false end                 -- nothing is tracked
            tex = t
            if tostring(t) == tostring(spellIcon(spellId)) then return true end
        end
    end
    -- 3. a tracking shows as a buff as well on some clients
    local names = auraNames("player")
    if names and name and names[name] then return true end
    if answered then return false end
    return nil                         -- no list; some other icon is tracked, or nothing readable: we cannot tell
end

M:Register({
    id = "tracking", name = "Turn on the tracking of a profession (Find Minerals, Find Herbs)",
    check = function()
        if InCombatLockdown() then return "keep" end
        if UnitIsDeadOrGhost("player") or (IsMounted and IsMounted()) then return nil end
        local wanted = {}
        for _, t in ipairs(M.TRACKING) do
            if knows(t.spell) then wanted[#wanted + 1] = t end
        end
        if #wanted == 0 then return nil end
        for _, t in ipairs(wanted) do
            if M.TrackingOn(t.spell) ~= false then return nil end     -- on, or not readable: no card
        end
        local out = {}
        for i = #wanted, 1, -1 do
            local t = wanted[i]
            local n = spellName(t.spell)
            if n then
                out[#out + 1] = {
                    key = "track:" .. t.spell, cast = n, unit = "player",
                    title = n, sub = "Tracking is off - click to see " .. t.what .. " on the minimap",
                    tag = "TRACKING", icon = spellIcon(t.spell), color = GREEN,
                }
            end
        end
        return out
    end,
})

----------------------------------------------------------------------
-- 6. Missing buffs
----------------------------------------------------------------------
local function unitInReach(unit)
    if UnitIsDeadOrGhost(unit) then return false end
    if UnitIsConnected and not UnitIsConnected(unit) then return false end
    if UnitIsVisible and not UnitIsVisible(unit) then return false end
    local guid = UnitGUID(unit)
    if guid and OMQ.Arrow and OMQ.Arrow.DistanceTo then
        local d = OMQ.Arrow:DistanceTo(guid)
        if d and d > BUFF_RANGE then return false end
    end
    return true
end

-- true when the unit is a group member who runs the addon
local function hasAddon(unit)
    local guid = UnitGUID(unit)
    local u = guid and OMQ.users[guid]
    return u ~= nil and OMQ:IsOnline(u)
end

-- Is a temporary enchantment (imbue, poison) on the main hand weapon?
-- Two sources, because not every client reports it the same way:
-- GetWeaponEnchantInfo and the imbue line in the weapon tooltip.
local lastImbueNames = nil

-- Text lines of the main hand tooltip: first the modern API, then a hidden tooltip
local scanTip
local function weaponLines()
    local out
    if C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
        local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", 16)
        if ok and type(data) == "table" and type(data.lines) == "table" then
            out = {}
            for _, line in ipairs(data.lines) do
                local text = line and line.leftText
                if type(text) == "string" and not isSecret(text) then out[#out + 1] = text end
            end
            if #out > 0 then return out, "C_TooltipInfo" end
        end
    end
    if CreateFrame then
        if not scanTip then
            local ok, tip = pcall(CreateFrame, "GameTooltip", "OneMoreQuestScanTip", nil, "GameTooltipTemplate")
            if ok and tip then scanTip = tip end
        end
        if scanTip and scanTip.SetOwner and scanTip.SetInventoryItem and scanTip.NumLines then
            local ok = pcall(function()
                scanTip:SetOwner(UIParent or WorldFrame, "ANCHOR_NONE")
                scanTip:ClearLines()
                scanTip:SetInventoryItem("player", 16)
            end)
            if ok then
                out = {}
                for i = 1, tonumber((scanTip:NumLines())) or 0 do
                    local fs = _G["OneMoreQuestScanTipTextLeft" .. i]
                    local text = fs and fs.GetText and fs:GetText()
                    if type(text) == "string" and not isSecret(text) then out[#out + 1] = text end
                end
                if #out > 0 then return out, "GameTooltip" end
            end
        end
    end
    return nil
end

-- The enchant on the weapon is not called like the spell: the spell is "Rockbiter
-- Weapon", the tooltip line reads "Rockbiter 3 (60 min)". So we drop the word all
-- imbue names share and match the distinctive part. No translation needed.
local IMBUE_SEEDS = { 8017, 8024, 8033, 8232 }
local function imbueBases(names)
    local all = {}
    for _, id in ipairs(IMBUE_SEEDS) do
        local n = spellName(id)
        if n then all[#all + 1] = n end
    end
    for n in pairs(names) do all[#all + 1] = n end
    local common
    if #all >= 2 then
        for _, n in ipairs(all) do
            local words = {}
            for w in n:gmatch("[^%s]+") do words[w:lower()] = true end
            if not common then common = words
            else for w in pairs(common) do if not words[w] then common[w] = nil end end end
        end
    end
    -- every distinctive word on its own: "Waffe der Flammenzunge" -> "flammenzunge"
    local bases, seen = {}, {}
    for n in pairs(names) do
        for w in n:gmatch("[^%s]+") do
            local lw = w:lower()
            if #lw >= 5 and not (common and common[lw]) and not seen[lw] then
                seen[lw] = true
                bases[#bases + 1] = lw
                -- German genitive: "Felsbeißers" on the spell, "Felsbeißer" on the weapon
                for cut = 1, 2 do
                    if #lw - cut >= 5 then bases[#bases + 1] = lw:sub(1, #lw - cut) end
                end
            end
        end
    end
    return bases
end

local function weaponTooltipHas(names)
    local lines = weaponLines()
    if not lines then return nil end
    -- every shaman imbue counts as "an imbue is on the weapon", also the ones without
    -- an alert (Frostbrand) and the ones not learned yet
    local all = {}
    for n in pairs(names) do all[n] = true end
    for _, id in ipairs(IMBUE_SEEDS) do
        local n = spellName(id)
        if n then all[n] = true end
    end
    names = all
    local bases = imbueBases(names)
    for _, text in ipairs(lines) do
        local low = text:lower()
        for n in pairs(names) do
            if n and text:find(n, 1, true) then return true end
        end
        for _, b in ipairs(bases) do
            if b ~= "" and low:find(b, 1, true) then return true end
        end
    end
    return false
end

-- returns true / false, or nil when nothing can be said
function M.WeaponEnchanted(names)
    local api
    if GetWeaponEnchantInfo then
        local function count(...) return select("#", ...), ... end
        local n, ok, v = count(pcall(GetWeaponEnchantInfo))
        if ok and n >= 2 and not isSecret(v) then
            if v == true or v == 1 then api = true
            elseif v == false or v == nil or v == 0 then api = false end
        end
    end
    if api then return true end
    if names and weaponTooltipHas(names) then return true end
    if api == false then return false end
    return nil
end

M:Register({
    id = "buff", name = "Buffs your class can cast that you or a group member lack",
    check = function()
        if InCombatLockdown() then return "keep" end
        if UnitIsDeadOrGhost("player") then return nil end
        local _, class = UnitClass("player")
        local groups = OMQ.buffGroups and OMQ.buffGroups[class]
        if not groups then return nil end
        local result = {}
        for _, g in ipairs(groups) do
            if g.kind == "weaponchoice" then
                -- one card per imbue the player knows, while the weapon has none
                local known, names = {}, {}
                for _, ch in ipairs(g.choices) do
                    local id = knowsAny(ch.cast)
                    if id then
                        local n = spellName(id)
                        known[#known + 1] = { ch = ch, id = id, name = n }
                        if n then names[n] = true end
                    end
                end
                lastImbueNames = names
                if #known > 0 and GetInventoryItemID("player", 16) then
                    if M.WeaponEnchanted(names) == false then
                        -- newest card is shown on top: add the last choice first so Rockbiter ends up on top
                        for i = #known, 1, -1 do
                            local k = known[i]
                            result[#result + 1] = {
                                key = "buff:self:" .. g.id .. ":" .. k.ch.id, color = PINK, icon = spellIcon(k.id),
                                cast = k.name, unit = "player",
                                text = "Weapon imbue: " .. (k.name or k.ch.id),
                            }
                        end
                    end
                end
            end
            if g.kind == "aurachoice" then
                -- any spell of the group on me is enough; otherwise one card per choice the player knows
                local names = auraNames("player")
                if names then
                    local covered = false
                    for _, id in ipairs(g.spells) do
                        local n = spellName(id)
                        if n and names[n] then covered = true; break end
                    end
                    if not covered then
                        local known = {}
                        for _, ch in ipairs(g.choices) do
                            local id = knowsAny(ch.cast)
                            if id then known[#known + 1] = { ch = ch, id = id, name = spellName(id) } end
                        end
                        -- the first choice ends up on top of the stack
                        for i = #known, 1, -1 do
                            local k = known[i]
                            result[#result + 1] = {
                                key = "buff:self:" .. g.id .. ":" .. k.ch.id, color = PINK, icon = spellIcon(k.id),
                                cast = k.name, unit = "player",
                                text = "You are missing " .. (k.name or k.ch.id),
                            }
                        end
                    end
                end
            end
            local castId = g.kind ~= "weaponchoice" and g.kind ~= "aurachoice" and knowsAny(g.cast)
            -- a buff that needs rage (Battle Shout, decision 208): only with enough rage
            if castId and g.minRage then
                local rage = UnitPower and UnitPower("player", (Enum and Enum.PowerType and Enum.PowerType.Rage) or 1)
                if type(rage) ~= "number" or isSecret(rage) or rage < g.minRage then castId = nil end
            end
            if castId then
                local lookNames
                if g.kind == "aura" then
                    lookNames = {}
                    for _, id in ipairs(g.spells) do
                        local n = spellName(id)
                        if n then lookNames[n] = true end
                    end
                end
                local gicon = spellIcon(castId)

                if g.kind == "weapon" then
                    if GetInventoryItemID("player", 16) then
                        if M.WeaponEnchanted(nil) == false then
                            result[#result + 1] = {
                                key = "buff:self:" .. g.id, color = PINK, icon = gicon,
                                cast = spellName(castId), unit = "player",
                                text = "You are missing " .. g.label,
                            }
                        end
                    end
                else
                    local units = { "player" }
                    if g.scope == "all" then
                        for i = 1, 4 do units[#units + 1] = "party" .. i end
                    end
                    for _, unit in ipairs(units) do
                        local wanted = unit == "player" or not OMQ.db.options.buffOnlyAddon or hasAddon(unit)
                        if wanted and UnitExists(unit) and (unit == "player" or unitInReach(unit)) then
                            local names = auraNames(unit)
                            if names then
                                local covered = false
                                for n in pairs(lookNames) do if names[n] then covered = true; break end end
                                if not covered then
                                    local who = unit == "player" and "You are" or ((UnitName(unit) or "?") .. " is")
                                    result[#result + 1] = {
                                        key = "buff:" .. (UnitGUID(unit) or unit) .. ":" .. g.id,
                                        text = who .. " missing " .. g.label,
                                        icon = gicon, color = PINK,
                                        cast = castFor(castId, unit), unit = unit,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
        return result
    end,
})

----------------------------------------------------------------------
-- 7. Unspent talent points
----------------------------------------------------------------------
-- Tries every known way to ask for unspent talent points. Returns the number,
-- plus a list of what each source answered (for /omq diag).
function M.UnspentTalents(report)
    local best, exact
    local function take(v)
        local isBool = (v == true)
        if isBool then v = 1 end
        if type(v) == "number" and not isSecret(v) and (not best or v > best) then
            best = v
            exact = not isBool
        end
    end
    local function try(label, fn)
        if not fn then
            if report then report[#report + 1] = label .. " = (does not exist)" end
            return
        end
        local res = { pcall(fn) }
        if report then
            local parts = {}
            for i = 2, #res do parts[#parts + 1] = isSecret(res[i]) and "secret" or tostring(res[i]) end
            report[#report + 1] = label .. " = " .. (res[1] and table.concat(parts, ", ") or ("error " .. tostring(res[2])))
        end
        if res[1] then take(res[2]) end
    end
    try("GetNumUnspentTalents", GetNumUnspentTalents)
    try("UnitCharacterPoints", UnitCharacterPoints and function() return UnitCharacterPoints("player") end)
    try("GetUnspentTalentPoints(false,false,group)", GetUnspentTalentPoints and function()
        return GetUnspentTalentPoints(false, false, GetActiveTalentGroup and GetActiveTalentGroup(false, false) or 1)
    end)
    -- modern client: returns a boolean (and maybe more)
    -- only the first answer counts (the following ones may belong to hero talents)
    try("C_ClassTalents.HasUnspentTalentPoints", C_ClassTalents and C_ClassTalents.HasUnspentTalentPoints and function()
        return (C_ClassTalents.HasUnspentTalentPoints())
    end)
    -- (HasPlayerEarnedATalentPoint is left out: it only says a point was ever earned)
    -- tier talents: a tier that is unlocked but has no choice yet
    try("talent tiers without a choice", GetMaxTalentTier and GetTalentTierInfo and function()
        local group = GetActiveTalentGroup and GetActiveTalentGroup(false, false) or 1
        local open = 0
        for tier = 1, GetMaxTalentTier() do
            local available, selected = GetTalentTierInfo(tier, group)
            if available and (selected == 0 or selected == nil) then open = open + 1 end
        end
        return open
    end)
    return best, exact
end

-- opens the talent tree: WoW Forever's player spells frame, older clients' talent frame (decision 234)
function M.OpenTalents()
    local P = PlayerSpellsUtil
    local tries = {
        P and P.OpenToClassTalentsTab or false,
        P and P.ToggleClassTalentOrSpecFrame or false,
        ToggleTalentFrame or false,
    }
    for _, fn in ipairs(tries) do
        if type(fn) == "function" then
            local ok, err = pcall(fn)
            if ok then return true end
            M.talentOpenError = tostring(err)
        end
    end
    OMQ:Print("Could not open the talent tree" .. (M.talentOpenError and (": " .. M.talentOpenError) or "") .. " - press N")
    return false
end

M:Register({
    id = "talent", name = "Unspent talent points",
    check = function()
        local n, exact = M.UnspentTalents()
        if type(n) == "number" and n > 0 then
            return { {
                key = "talent",
                text = exact == false and "You have unspent talent points"
                    or (n .. " unspent talent point" .. (n == 1 and "" or "s")),
                icon = "Interface\\Icons\\Ability_Marksmanship", color = GOLD,
                open = M.OpenTalents,          -- a click opens the talent tree (decision 234)
            } }
        end
    end,
})

----------------------------------------------------------------------
-- 8. Low ammo
----------------------------------------------------------------------
M:Register({
    id = "ammo", name = "Ammo below 200 pieces",
    check = function()
        -- hunters: count the ammo in the bags, so an empty quiver still warns
        if OMQ.QoL and OMQ.QoL.AmmoStatus then
            local sub, have = OMQ.QoL:AmmoStatus()
            if sub then
                if have < AMMO_BELOW then
                    return { {
                        key = "ammo", text = have == 0 and "Out of ammo" or ("Low ammo: " .. have .. " left"),
                        icon = sub == 2 and "Interface\\Icons\\INV_Ammo_Arrow_02" or "Interface\\Icons\\INV_Ammo_Bullet_01",
                        color = RUST,
                    } }
                end
                return nil
            end
        end
        if not GetInventoryItemLink("player", 0) then return nil end   -- no ammo equipped
        local count = GetInventoryItemCount("player", 0)
        if type(count) == "number" and count < AMMO_BELOW then
            return { {
                key = "ammo", text = "Low ammo: " .. count .. " left",
                icon = GetInventoryItemTexture("player", 0) or "Interface\\Icons\\INV_Ammo_Arrow_02",
                color = RUST,
            } }
        end
    end,
})


----------------------------------------------------------------------
-- /omq diag: raw answers of the APIs behind the alerts, for bug reports
----------------------------------------------------------------------
OMQ:RegisterCommand("diag", function(arg)
    if arg == "guide" and OMQ.GuideProbe then return OMQ.GuideProbe() end
    local out = {}
    local function add(t) out[#out + 1] = t end
    local function show(v) if isSecret(v) then return "SECRET" end return tostring(v) end
    add("One More Quest " .. OMQ.version .. " diagnosis")
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    add("map " .. show(map) .. ", major city: " .. tostring(OMQ:InMajorCity()) .. ", level " .. show(UnitLevel("player")))
    local mana = Enum and Enum.PowerType and Enum.PowerType.Mana or 0
    local cur, max = UnitPower("player", mana), UnitPowerMax("player", mana)
    add("mana " .. show(cur) .. " / " .. show(max) .. ", power type " .. show((UnitPowerType("player"))) ..
        ", combat " .. tostring(InCombatLockdown()) .. ", mounted " .. tostring(IsMounted and IsMounted()))
    add("mana card: " .. (OMQ.ManaCard and OMQ.ManaCard.Status() or "missing") ..
        ", UnitPowerPercent " .. tostring(UnitPowerPercent ~= nil) .. ", C_CurveUtil " .. tostring(C_CurveUtil ~= nil) ..
        ", LuaCurveType " .. tostring(Enum and Enum.LuaCurveType ~= nil))
    if OMQ.Pull then add(OMQ.Pull.Diag()) end
    -- Battle Shout (decisions 208, 212): what the game lets us read
    do
        local rage = UnitPower("player", (Enum and Enum.PowerType and Enum.PowerType.Rage) or 1)
        local known
        for _, g in ipairs(OMQ.buffGroups and OMQ.buffGroups.WARRIOR or {}) do
            if g.id == "battleshout" then known = knowsAny(g.cast) end
        end
        add("battle shout: rage " .. show(rage) .. ", learned rank id " .. tostring(known) ..
            ", rage card wants " .. tostring(OMQ.RageCard and OMQ.RageCard.Wanted() or nil))
    end
    local report = {}
    local n = M.UnspentTalents(report)
    add("talents -> " .. tostring(n))
    for _, r in ipairs(report) do add("  " .. r) end
    if C_SpecializationInfo and C_SpecializationInfo.HasPlayerEarnedATalentPoint then
        add("  (info only) HasPlayerEarnedATalentPoint = " .. tostring((C_SpecializationInfo.HasPlayerEarnedATalentPoint())))
    end
    if C_ClassTalents and C_ClassTalents.HasUnspentTalentPoints then
        add("  (info only) HasUnspentTalentPoints all answers: " .. (function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end return table.concat(t, ", ") end)(C_ClassTalents.HasUnspentTalentPoints()))
    end
    -- every function whose name suggests talents, to find the right one
    local found = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "function" and (k:find("Talent") or k:find("Unspent")) then found[#found + 1] = k end
        if type(k) == "string" and type(v) == "table" and k:find("^C_") then
            for k2, v2 in pairs(v) do
                if type(k2) == "string" and type(v2) == "function" and (k2:find("Talent") or k2:find("Unspent")) then
                    found[#found + 1] = k .. "." .. k2
                end
            end
        end
    end
    table.sort(found)
    add("talent-like functions (" .. #found .. "): " .. table.concat(found, ", "))
    -- spell ranks: highest learned rank vs what the bars hold
    local best = highestRanks()
    if best then
        local names, ids = barSpells()
        local count = 0
        for name, sp in pairs(best) do
            if sp.rank > 1 or names[name] then
                count = count + 1
                if count <= 25 then
                    add(string.format("  rank %s %d id %d: on bar by id %s, by name %s", name, sp.rank, sp.spellID,
                        tostring(ids[sp.spellID] or false), tostring(names[name] or false)))
                end
            end
        end
        add("  strict rank check: " .. tostring(not OMQ.db.alerts.lenientRank))
    else
        add("  spellbook not readable")
    end
    if GetWeaponEnchantInfo then
        local r = { pcall(GetWeaponEnchantInfo) }
        local parts = {}
        for i = 2, #r do parts[#parts + 1] = isSecret(r[i]) and "SECRET" or tostring(r[i]) end
        add("weapon enchant: " .. (r[1] and table.concat(parts, ", ") or ("error " .. tostring(r[2]))) ..
            ", judged " .. tostring(M.WeaponEnchanted(lastImbueNames)))
    else
        add("weapon enchant: GetWeaponEnchantInfo does not exist")
    end
    do
        local lines, via = weaponLines()
        add("main hand tooltip (" .. tostring(via) .. "): " .. (lines and (#lines .. " lines") or "not readable"))
        for i, t in ipairs(lines or {}) do if i <= 14 then add("  | " .. t) end end
        local link = GetInventoryItemLink and GetInventoryItemLink("player", 16)
        add("main hand link: " .. ((link and not isSecret(link)) and (link:gsub("|", "||")) or tostring(link)))
        local known = {}
        for n in pairs(lastImbueNames or {}) do known[#known + 1] = n end
        add("imbue names checked: " .. (#known > 0 and table.concat(known, ", ") or "none yet (open /omq diag after the buff check ran)"))
    end
    if OMQ.QoL and OMQ.QoL.AmmoLines then
        local ok, lines = pcall(OMQ.QoL.AmmoLines, OMQ.QoL)
        for _, l in ipairs(ok and lines or { "ammo: error " .. tostring(lines) }) do add(l) end
    end
    add("GetProfessions: " .. tostring(GetProfessions ~= nil) .. ", GetNumSkillLines: " .. tostring(GetNumSkillLines ~= nil))
    local lines = professionLines()
    if lines then
        for _, l in ipairs(lines) do add("  " .. l.name .. " " .. l.rank .. "/" .. l.max) end
    else
        add("  no profession data")
    end
    for id, why in pairs(M.unavailable or {}) do add("unavailable: " .. id .. " - " .. why) end
    for _, rid in ipairs(M.ruleOrder) do
        local ok, res = pcall(M.rules[rid].check)
        add("rule " .. rid .. ": " .. (ok and (type(res) == "table" and (#res .. " alert(s)") or tostring(res)) or ("ERROR " .. tostring(res))))
    end
    for _, e in ipairs(OMQ.errors or {}) do add("error: " .. e) end
    OMQ:ShowReport(out)
end, "open a copyable report with raw values behind the alerts (for bug reports)")
