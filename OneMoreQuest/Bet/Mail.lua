-- One More Quest: Bet Check at the mailbox (chapter 22, decisions 170, 174, 175)
-- The player clicks the mailbox himself (an addon card cannot open it, decision 174). Then:
--   1. collect: money and items of every mail (option "Open all mail at the mailbox", default on);
--      switched off, only the bet mails. Mails with cash on delivery and GM mails are left alone.
--   2. bet mails are deleted as soon as they are empty (decision 175); the funny line goes to the chat.
--   3. pay: every open debt the gold covers (stake + postage) is sent to the winner's full name;
--      MAIL_SEND_SUCCESS marks it paid and tells the winner (BP). A failure stays open for the next mailbox.
--   4. optional: close the mailbox afterwards (option, default off).
-- One action every STEP seconds, because the inbox updates after each action.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local BM = {}
OMQ.BetMail = BM

local STEP = 0.5
local START_DELAY = 0.5        -- MAIL_SHOW -> first action (the probe sent after 0.5 s)
local SEND_TIMEOUT = 10
local MAX_TRIES = 3            -- per mail and action
local NEAR_YARDS = 15
local POSTAGE = 30             -- fallback when GetSendMailPrice gives nothing
local SUBJECT = "One More Quest bet"
BM.SUBJECT, BM.NEAR_YARDS = SUBJECT, NEAR_YARDS

local GREEN  = { 0.49, 0.78, 0.44 }
local ORANGE = { 0.91, 0.66, 0.24 }

local isOpen = false
local ticker
local phase                    -- "collect", "pay", "done"
local tries = {}               -- key -> count (this visit)
local skipped = {}             -- owe entries skipped this visit
local pending                  -- { entry, at } while a payment is on its way
local didBet = false           -- something bet related happened (for the close option)
local poorSaid = {}

local function isSecret(v) return issecretvalue and issecretvalue(v) or false end
local function now() return GetTime() end
local function money(c) return OMQ.Bets.Money(c) end

local function opt(k)
    local o = OMQ.db and OMQ.db.options and OMQ.db.options.qol
    return o and o[k]
end
-- open all mail: on unless switched off, and only with the vendor master on
local function openAll() return OMQ:Master("vendor") and opt("openmail") ~= false end
local function closeAfter() return opt("closemail") == true end

function BM.IsBetSubject(subject)
    return type(subject) == "string" and not isSecret(subject) and subject:sub(1, #SUBJECT) == SUBJECT
end

local function busy()
    return C_Mail and C_Mail.IsCommandPending and C_Mail.IsCommandPending() or false
end

local function try(key)
    tries[key] = (tries[key] or 0) + 1
    return tries[key] <= MAX_TRIES
end

----------------------------------------------------------------------
-- Ledger matching for a bet mail
----------------------------------------------------------------------
-- the "get" entry this mail pays: same bet id, from that sender (first name) or with that amount
local function matchGet(subject, sender, amount)
    local id = subject:sub(#SUBJECT + 2):match("^(%S+)")
    if not id then return nil end
    local list = OMQ.Bets.Ledger().get
    local first = type(sender) == "string" and not isSecret(sender) and sender:match("^(%S+)") or nil
    local byAmount
    for _, e in ipairs(list) do
        if e.id == id and e.state ~= "done" then
            if first and e.fromName == first then return e end
            if not byAmount and e.amount == amount then byAmount = e end
        end
    end
    return byAmount
end

----------------------------------------------------------------------
-- 1 + 2: collect and delete (one action per call; returns true if it did something)
----------------------------------------------------------------------
local function collectStep()
    local n = GetInboxNumItems and GetInboxNumItems() or 0
    local all = openAll()
    for i = n, 1, -1 do
        local ok, _, _, sender, subject, cash, cod, _, hasItem, wasRead, _, _, _, isGM = pcall(GetInboxHeaderInfo, i)
        if ok and not isSecret(cash) then
            local bet = BM.IsBetSubject(subject)
            cash = tonumber(cash) or 0
            local codOk = not (type(cod) == "number" and cod > 0)
            local key = tostring(sender) .. "|" .. tostring(subject) .. "|" .. i
            if codOk and not isGM and (bet or all) then
                if cash > 0 or (hasItem and hasItem ~= 0) then
                    if try("take:" .. key) then
                        if bet and cash > 0 and tries["take:" .. key] == 1 then
                            local e = matchGet(subject, sender, cash)
                            local from = (e and e.fromName) or (type(sender) == "string" and not isSecret(sender) and sender) or "a dad"
                            if e then e.state = "done"; e.doneAt = time() end
                            OMQ:Print(string.format("Bet earnings: %s from %s. %s", money(cash), from, OMQ.Bets.FunnyLine()))
                            didBet = true
                            OMQ:Fire("BETS_CHANGED")
                        end
                        if hasItem and hasItem ~= 0 and AutoLootMailItem then
                            pcall(AutoLootMailItem, i)
                        else
                            if cash > 0 then pcall(TakeInboxMoney, i) end
                            if hasItem and hasItem ~= 0 and TakeInboxItem then pcall(TakeInboxItem, i, 1) end
                        end
                        return true
                    end
                elseif bet then
                    -- empty bet mail: delete it (decision 175)
                    if try("del:" .. key) and DeleteInboxItem then
                        pcall(DeleteInboxItem, i)
                        didBet = true
                        return true
                    end
                elseif not wasRead and GetInboxText then
                    if try("read:" .. key) then pcall(GetInboxText, i); return true end
                end
            end
        end
    end
    return false
end

----------------------------------------------------------------------
-- 3: pay the debts
----------------------------------------------------------------------
local function postage()
    local p = GetSendMailPrice and GetSendMailPrice()
    return (type(p) == "number" and not isSecret(p) and p > 0) and p or POSTAGE
end

local function payStep()
    local l = OMQ.Bets.Ledger()
    for _, e in ipairs(l.owe) do
        -- bet simulator: a debt to the fake dad is not mailed (it goes when the simulator ends)
        if e.state ~= "paid" and not skipped[e] and OMQ.Bets.TestMode() and OMQ.Sim:IsSim(e.to) then
            skipped[e] = true
        end
        if e.state ~= "paid" and not skipped[e] then
            if not e.toFull or e.toFull == "" then e.toFull = OMQ.Bets.FullNameOf(e.to) end
            if not e.toFull then
                skipped[e] = true
                OMQ:Print("Bet debt to " .. (e.toName or "?") .. ": name unknown, the next mailbox tries again.")
            elseif (GetMoney() or 0) < e.amount + postage() then
                skipped[e] = true
                if not poorSaid[e] then
                    poorSaid[e] = true
                    OMQ:Print(string.format("Not enough gold for %s to %s: stays open, the next mailbox tries again.", money(e.amount), e.toName or "?"))
                end
            else
                local kind = OMQ.Bets.KIND[e.kind]
                local body = string.format("You won the bet \"%s\": %s. %s", kind and kind.name or "?", money(e.amount),
                    OMQ.Bets.FunnyLine())
                if ClearSendMail then pcall(ClearSendMail) end
                pcall(SetSendMailMoney, e.amount)
                local ok = pcall(SendMail, e.toFull, SUBJECT .. " " .. e.id, body)
                if ok then
                    pending = { entry = e, at = now() }
                    didBet = true
                else
                    skipped[e] = true
                end
                return true
            end
        end
    end
    return false
end

----------------------------------------------------------------------
-- The queue
----------------------------------------------------------------------
local function stop()
    if ticker then ticker:Cancel(); ticker = nil end
end

function BM.Step()
    if not isOpen then stop(); return end
    if pending then
        if now() - pending.at > SEND_TIMEOUT then
            skipped[pending.entry] = true
            pending = nil
        else
            return
        end
    end
    if busy() then return end
    if phase == "collect" then
        if collectStep() then return end
        phase = "pay"
    end
    if phase == "pay" then
        if payStep() then return end
        phase = "done"
        if didBet and closeAfter() and CloseMail then pcall(CloseMail) end
        stop()
    end
end

local function start()
    tries, skipped, pending, didBet, poorSaid = {}, {}, nil, false, {}
    phase = "collect"
    stop()
    C_Timer.After(START_DELAY, function()
        if not isOpen then return end
        BM.Step()
        if isOpen and phase ~= "done" and not ticker then ticker = C_Timer.NewTicker(STEP, BM.Step) end
    end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SHOW" then
        isOpen = true
        start()
    elseif event == "MAIL_CLOSED" then
        isOpen = false
        pending = nil
        stop()
    elseif event == "MAIL_SEND_SUCCESS" then
        if pending then
            local e = pending.entry
            pending = nil
            OMQ.Bets:Paid(e)
            OMQ:Print(string.format("Bet debt paid: %s to %s.", money(e.amount), e.toName or "?"))
        end
    elseif event == "MAIL_FAILED" then
        if pending then
            skipped[pending.entry] = true
            pending = nil
            if ClearSendMail then pcall(ClearSendMail) end
        end
    end
end)

function BM.IsOpen() return isOpen end
function BM.Phase() return phase end

----------------------------------------------------------------------
-- The alert card near a mailbox (decision 174: a hint, the player clicks the mailbox)
----------------------------------------------------------------------
local function nearMailbox()
    if not (UnitPosition and OMQ.Places) then return false end
    local a, b, _, inst = UnitPosition("player")
    if type(a) ~= "number" or isSecret(a) or isSecret(b) then return false end
    for _, p in ipairs(OMQ.Places:All("mailbox")) do
        if p.inst == inst and math.sqrt((p.a - a) ^ 2 + (p.b - b) ^ 2) <= NEAR_YARDS then return true end
    end
    return false
end

function BM.AlertCheck()
    if isOpen or not OMQ.Bets then return nil end
    local l = OMQ.Bets.Ledger()
    local owe, collect = 0, false
    for _, e in ipairs(l.owe) do if e.state ~= "paid" then owe = owe + e.amount end end
    for _, e in ipairs(l.get) do
        if e.state == "sent" or (e.state == "open" and HasNewMail and HasNewMail()) then collect = true end
    end
    if owe == 0 and not collect then return nil end
    if not nearMailbox() then return nil end
    if owe > 0 then
        return { { key = "betmail:pay", text = "Mailbox nearby - Pay your debt: " .. money(owe),
                   icon = "Interface\\Icons\\INV_Letter_15", color = ORANGE } }
    end
    return { { key = "betmail:get", text = "Mailbox nearby - Get your earnings",
               icon = "Interface\\Icons\\INV_Letter_15", color = GREEN } }
end

if OMQ.Alerts then
    OMQ.Alerts:Register({ id = "betmail", name = "Bet Balance on Mailbox", check = BM.AlertCheck })
end
