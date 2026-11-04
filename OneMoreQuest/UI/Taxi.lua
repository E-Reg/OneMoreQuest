-- One More Quest: flight time bar (reads Stats/Taxi.lua)
-- A small bar at the top of the screen while flying: "Flying to <node> · 1:52", counting down; "~" marks an
-- estimate for a route nobody measured yet; without any time only the destination.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

local B = {}
OMQ.TaxiUI = B
local X = OMQ.Taxi

local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil
local BODY_FONT = "Fonts\\FRIZQT__.TTF"

local function mmss(s) s = math.max(0, math.floor(s + 0.5)); return string.format("%d:%02d", math.floor(s / 60), s % 60) end
B.Clock = mmss

function B:Text()
    local f = X.flight
    if not (f and f.name) then return nil end
    local left, est = X:Left()
    if not left then return "Flying to " .. f.name end
    return "Flying to " .. f.name .. " · " .. (est and "~" or "") .. mmss(left)
end

function B:Build()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "OneMoreQuestTaxiBar", UIParent, BACKDROP)
    f:SetSize(260, 26)
    f:SetPoint("TOP", UIParent, "TOP", 0, -72)
    f:SetFrameStrata("MEDIUM")
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
                        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropColor(.05, .05, .06, .9)
        f:SetBackdropBorderColor(.42, .35, .18, 1)
    end
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if f.text.SetFont then pcall(f.text.SetFont, f.text, BODY_FONT, 12, "") end
    f.text:SetPoint("CENTER")
    local acc = 0
    f:SetScript("OnUpdate", function(self, dt)
        acc = acc + (dt or 0)
        if acc < 0.25 then return end
        acc = 0
        B:Refresh()
    end)
    self.updating = true; f:Hide(); self.updating = false
    self.frame = f
    return f
end

function B:Refresh()
    local text = self:Text()
    if not text then
        if self.frame and self.frame:IsShown() then self.frame:Hide() end
        return
    end
    local f = self:Build()
    f.text:SetText(text)
    local w = f.text.GetStringWidth and f.text:GetStringWidth()
    if type(w) == "number" and w > 0 then f:SetWidth(math.max(160, w + 28)) end
    if not f:IsShown() then f:Show() end
end

OMQ:On("TAXI_CHANGED", function()
    local fine, err = pcall(B.Refresh, B)
    if not fine then OMQ:Error("taxi bar", err) end
end)
