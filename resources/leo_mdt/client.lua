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
        -- Request recent incidents from server so MDT can populate on open
        TriggerServerEvent('leo_dispatch:requestRecentIncidents')
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

-- Server responds with recent incidents
RegisterNetEvent('leo_dispatch:recentIncidents')
AddEventHandler('leo_dispatch:recentIncidents', function(incidents)
    -- forward to NUI
    SendNUIMessage({ type = 'initIncidents', incidents = incidents })
end)

-- Unit updates from AI manager -> forward to NUI
RegisterNetEvent('leo_dispatch:unitUpdate')
AddEventHandler('leo_dispatch:unitUpdate', function(unit)
    SendNUIMessage({ type = 'unitUpdate', unit = unit })
end)

-- Recent units response from AI manager
RegisterNetEvent('leo_ai_units:recentUnits')
AddEventHandler('leo_ai_units:recentUnits', function(units)
    SendNUIMessage({ type = 'recentUnits', units = units })
end)

RegisterNUICallback('close', function(data, cb)
    setDisplay(false)
    cb('ok')
end)

-- NUI callback: request units for incident
RegisterNUICallback('requestUnits', function(data, cb)
    local incident_id = data.incident_id
    TriggerServerEvent('leo_ai_units:requestUnits', incident_id)
    cb('ok')
end)

-- NUI callback: assign unit for incident
RegisterNUICallback('assignUnit', function(data, cb)
    local incident_id = data.incident_id
    local template = data.template
    -- Build incident object and trigger server-side assign event
    local incident = { incident_id = incident_id, coords = template.spawnCoords }
    TriggerServerEvent('leo_ai_units:assign', incident, template)
    cb('ok')
end)

-- For compatibility with our fetch POST endpoints (simple mapping)
-- The NUI uses fetch('https://leo_mdt/assignUnit', ...)
RegisterNUICallback('assignUnit', function(data, cb)
    -- This receiver will be called; it's defined above but keep for clarity
    local incident_id = data.incident_id
    local template = data.template
    local incident = { incident_id = incident_id, coords = template.spawnCoords }
    TriggerServerEvent('leo_ai_units:assign', incident, template)
    cb('ok')
end)

-- Request units endpoint mapping from fetch('https://leo_mdt/requestUnits')
RegisterNUICallback('requestUnits', function(data, cb)
    local incident_id = data.incident_id
    TriggerServerEvent('leo_ai_units:requestUnits', incident_id)
    cb('ok')
end)
