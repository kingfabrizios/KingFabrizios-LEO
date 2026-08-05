-- resources/leo_ai_units/server.lua
-- Server-side AI unit manager (skeleton).
-- Maintains unit state and requests a client host to spawn AI peds/vehicles.

local activeUnits = {}
local unitCounter = 0
local incidentToUnits = {}
local QBCore = exports['qb-core']:GetCoreObject()

-- Choose a host player to spawn AI. Simple strategy: pick the first connected player.
-- Later: choose nearest to incident or a dedicated host role.
local function chooseHostForIncident(incident)
    local players = GetPlayers()
    if not players or #players == 0 then return nil end
    -- pick the first active player (server id as string) — better strategies can be implemented later
    return tonumber(players[1])
end

-- Assign a single unit to an incident using a template:
-- template = { unit_type = 'patrol', pedModel = 's_m_y_cop_01', vehicleModel = 'police', spawnCoords = {x,y,z}, behavior = 'drive_to_scene' }
local function assignUnitToIncident(incident, template)
    local host = chooseHostForIncident(incident)
    if not host then
        print('[leo_ai_units] No host players available to spawn AI')
        return nil
    end

    unitCounter = unitCounter + 1
    local unit = {
        unit_id = unitCounter,
        incident_id = incident.incident_id or incident.id or 0,
        unit_type = template.unit_type or 'unit',
        pedModel = template.pedModel,
        vehicleModel = template.vehicleModel,
        coords = template.spawnCoords or template.coords or { x = 0.0, y = 0.0, z = 0.0 },
        behavior = template.behavior or 'drive_to_scene',
        status = 'queued',
        host = host
    }

    activeUnits[unit.unit_id] = unit
    incidentToUnits[unit.incident_id] = incidentToUnits[unit.incident_id] or {}
    table.insert(incidentToUnits[unit.incident_id], unit.unit_id)

    -- Ask the host client to spawn the unit
    print(('[leo_ai_units] Requesting spawn of unit %d on host %s'):format(unit.unit_id, tostring(host)))
    TriggerClientEvent('leo_ai_units:spawnRequest', host, unit)

    return unit.unit_id
end

-- Exposed event to assign units (other server code can TriggerEvent or TriggerServerEvent)
RegisterNetEvent('leo_ai_units:assign')
AddEventHandler('leo_ai_units:assign', function(incident, template)
    assignUnitToIncident(incident, template)
end)

-- Debug console command to assign a test unit to an incident id
RegisterCommand('leo_assign', function(source, args, raw)
    if source ~= 0 then
        print('[leo_ai_units] This command may only be run from the server console')
        return
    end

    local incident_id = tonumber(args[1]) or nil
    if not incident_id then
        print('Usage: leo_assign <incident_id>')
        return
    end

    -- Build a simple template and call assign
    local template = {
        unit_type = 'patrol',
        pedModel = 's_m_y_cop_01',
        vehicleModel = 'police',
        spawnCoords = { x = tonumber(args[2]) or 0.0, y = tonumber(args[3]) or 0.0, z = tonumber(args[4]) or 0.0 },
        behavior = 'drive_to_scene'
    }

    local incident = { incident_id = incident_id }
    local uid = assignUnitToIncident(incident, template)
    if uid then
        print(('[leo_ai_units] Assigned unit %d to incident %d'):format(uid, incident_id))
    end
end, false)

-- Handler: client notifies server that it spawned the unit and provides network id
RegisterNetEvent('leo_ai_units:clientSpawned')
AddEventHandler('leo_ai_units:clientSpawned', function(data)
    local src = source
    if not data or not data.unit_id then return end
    local unit = activeUnits[data.unit_id]
    if not unit then
        print(('[leo_ai_units] clientSpawned for unknown unit %s from %s'):format(tostring(data.unit_id), tostring(src)))
        return
    end

    unit.netId = data.netId
    unit.entityType = data.entityType -- 'ped' or 'vehicle'
    unit.status = 'enroute'
    unit.host = src

    print(('[leo_ai_units] Unit %d spawned by host %s (netId=%s)'):format(unit.unit_id, tostring(src), tostring(unit.netId)))

    -- Broadcast update to clients/MDT
    TriggerClientEvent('leo_dispatch:unitUpdate', -1, unit)
end)

-- Handler: client status update
RegisterNetEvent('leo_ai_units:clientStatus')
AddEventHandler('leo_ai_units:clientStatus', function(data)
    local src = source
    if not data or not data.unit_id then return end
    local unit = activeUnits[data.unit_id]
    if not unit then return end

    unit.status = data.status or unit.status
    unit.position = data.position or unit.position

    -- Broadcast to clients/MDT
    TriggerClientEvent('leo_dispatch:unitUpdate', -1, unit)
end)

-- Optional cleanup: client notifies server when unit is despawned
RegisterNetEvent('leo_ai_units:clientDespawn')
AddEventHandler('leo_ai_units:clientDespawn', function(data)
    if not data or not data.unit_id then return end
    local unit = activeUnits[data.unit_id]
    if not unit then return end

    unit.status = 'despawned'
    unit.despawned_at = os.time()
    TriggerClientEvent('leo_dispatch:unitUpdate', -1, unit)

    -- remove from activeUnits and incidentToUnits
    activeUnits[data.unit_id] = nil
    local list = incidentToUnits[unit.incident_id]
    if list then
        for i = #list, 1, -1 do
            if list[i] == data.unit_id then
                table.remove(list, i)
            end
        end
    end
end)

-- Export simple helper for server code to request assignment
exports('assignUnitToIncident', assignUnitToIncident)

print('[leo_ai_units] Server loaded')
