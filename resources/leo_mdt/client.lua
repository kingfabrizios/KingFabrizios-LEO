-- leo_mdt/client.lua
-- Client-side MDT integration with QBCore permission request: opens NUI only for authorized users

local QBCore = exports['qb-core']:GetCoreObject()
local display = false

-- Open MDT UI locally
local function setDisplay(bool)
    display = bool
    SetNuiFocus(bool, bool)
    SendNUIMessage({ type = 'toggle', display = bool })
end

-- Request open from server (server will validate permissions)
RegisterCommand('mdt', function()
    TriggerServerEvent('leo_mdt:requestOpen')
end, false)

-- Server response: open if authorized
RegisterNetEvent('leo_mdt:openAuthorized')
AddEventHandler('leo_mdt:openAuthorized', function(allowed)
    if allowed then
        setDisplay(true)
    else
        -- Use QBCore notification if available
        if QBCore and QBCore.Functions and QBCore.Functions.Notify then
            QBCore.Functions.Notify('You are not authorized to use the MDT.', 'error')
        else
            print('[leo_mdt] Not authorized to open MDT')
        end
    end
end)

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
