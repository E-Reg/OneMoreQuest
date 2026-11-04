-- One More Quest: Main
-- Glue code.
local ADDON, OMQ = ...
OMQ = _G.OneMoreQuest

OMQ:On("READY", function()
    local me = OMQ:GetSelf()
    if me then
        OMQ:Print("v" .. OMQ.version .. " loaded for " .. me.name)
    end
end)
