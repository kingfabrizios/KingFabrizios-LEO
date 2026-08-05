-- leo_mdt/client.lua
-- Minimal client-side MDT integration: opens NUI and listens for dispatch events

local display = false

-- Open MDT UI
local function setDisplay(bool)
    display = bool
    SetNuiFocus(bool, bool)
    SendNUIMessage({ type = 'toggle', display = bool })
end

RegisterCommand('mdt', function()
    setDisplay(true)
end, false)

RegisterNUICallback('close', function(data, cb)
    setDisplay(false)
    cb('ok')
end)

-- Listen for dispatch incidents from server and forward to NUI
RegisterNetEvent('leo_dispatch:incidentCreated')
AddEventHandler('leo_dispatch:incidentCreated', function(incident)
    -- Forward to NUI; if MDT isn't open it can still receive (MDT should cache)
    SendNUIMessage({ type = 'incident', incident = incident })
end)
