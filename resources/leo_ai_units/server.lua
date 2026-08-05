-- resources/leo_ai_units/server.lua
-- Server-side AI unit manager with DB persistence for unit records (incidents_units table).

local activeUnits = {}
local unitCounter = 0
local incidentToUnits = {}
local incidentsStore = {}
local QBCore = exports['qb-core']:GetCoreObject()

-- DB availability
local hasOx = exports['oxmysql'] ~= nil

-- Limits
local MAX_UNITS_PER_HOST = 4
local MAX_UNITS_PER_INCIDENT = 6

-- runtime counters & queues
local hostActiveCount = {}         -- hostId -> number of active (spawned) units
local incidentActiveCount = {}     -- incident_id -> number of active (spawned) units
local pendingQueue = {}            -- hostId -> list of queued unit objects awaiting spawn on that host

local function countPendingForIncident(incident_id)
    local c = 0
    for _, list in pairs(pendingQueue) do
        for _, u in ipairs(list) do
            if u.incident_id == incident_id then c = c + 1 end
        end
    end
    return c
end

-- Ensure DB table exists on resource start (attempt)
AddEventHandler('onResourceStart', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then return end
    if not hasOx then
        print('[leo_ai_units] oxmysql not available; unit persistence disabled')
        return
    end

    local schema = [[
    CREATE TABLE IF NOT EXISTS `incidents_units` (
        `id` INT AUTO_INCREMENT PRIMARY KEY,
        `unit_id` INT NOT NULL,
        `incident_id` INT NOT NULL,
        `unit_type` VARCHAR(64),
        `ped_model` VARCHAR(128),
        `vehicle_model` VARCHAR(128),
        `host` INT,
        `net_id` VARCHAR(64),
        `status` VARCHAR(64),
        `spawned_at` TIMESTAMP NULL DEFAULT NULL,
        `despawned_at` TIMESTAMP NULL DEFAULT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]

    exports.oxmysql:execute(schema, {}, function()
        print('[leo_ai_units] incidents_units table ready')
    end)
end)

-- Choose a host player to spawn AI.
local function chooseHostForIncident(incident, fallbackCoords)
    local players = GetPlayers()
    if not players or #players == 0 then return nil end

    -- 1) dedicated host role
    for _, pid in ipairs(players) do
        local player = tonumber(pid)
        local ok, ply = pcall(function() return QBCore.Functions.GetPlayer(player) end)
        if ok and ply and ply.PlayerData and ply.PlayerData.job and ply.PlayerData.job.name == 'ai_host' then
            print(('[leo_ai_units] Chose dedicated ai_host player %s as host'):format(tostring(player)))
            return player
        end
    end

    -- Determine target coords to compute proximity
    local tx, ty, tz = nil, nil, nil
    if incident and incident.coords and incident.coords.x then
        tx, ty, tz = incident.coords.x, incident.coords.y, incident.coords.z
    elseif fallbackCoords and fallbackCoords.x then
        tx, ty, tz = fallbackCoords.x, fallbackCoords.y, fallbackCoords.z
    end

    -- 2) nearest player to target coords
    if tx then
        local best, bestDist = nil, math.huge
        for _, pid in ipairs(players) do
            local player = tonumber(pid)
            local ped = GetPlayerPed(player)
            if ped and ped > 0 then
                local px, py, pz = table.unpack(GetEntityCoords(ped, true))
                local dx = px - tx
                local dy = py - ty
                local dz = (pz or 0.0) - (tz or 0.0)
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist < bestDist then
                    bestDist = dist
                    best = player
                end
            end
        end
        if best then
            print(('[leo_ai_units] Chose nearest player %s (dist=%.1f) as host for coords (%.1f, %.1f, %.1f)'):format(tostring(best), bestDist, tx, ty, tz))
            return best
        end
    end

    -- 3) fallback to first player
    print(('[leo_ai_units] No dedicated host or proximate player; falling back to first connected player %s'):format(tostring(players[1])))
    return tonumber(players[1])
end

-- Assign a single unit to an incident using a template
local function assignUnitToIncident(incident, template)
    -- choose host considering incident coords or template spawnCoords as fallback
    local host = chooseHostForIncident(incident, template and template.spawnCoords)
    if not host then
        print('[leo_ai_units] No host players available to spawn AI')
        return nil
    end

    local incident_id = incident.incident_id or incident.id or 0

    -- check per-incident limit including queued
    local activeForIncident = incidentActiveCount[incident_id] or 0
    local pendingForIncident = countPendingForIncident(incident_id)
    if (activeForIncident + pendingForIncident) >= MAX_UNITS_PER_INCIDENT then
        print(('[leo_ai_units] Incident %s has reached max units (%d active + %d pending >= %d)'):
            format(tostring(incident_id), activeForIncident, pendingForIncident, MAX_UNITS_PER_INCIDENT))
        return nil
    end

    unitCounter = unitCounter + 1
    local unit = {
        unit_id = unitCounter,
        incident_id = incident_id,
        unit_type = template.unit_type or 'unit',
        pedModel = template.pedModel,
        vehicleModel = template.vehicleModel,
        coords = template.spawnCoords or template.coords or (incident and incident.coords) or { x = 0.0, y = 0.0, z = 0.0 },
        behavior = template.behavior or 'drive_to_scene',
        status = 'queued',
        host = host
    }

    activeUnits[unit.unit_id] = unit
    incidentToUnits[unit.incident_id] = incidentToUnits[unit.incident_id] or {}
    table.insert(incidentToUnits[unit.incident_id], unit.unit_id)

    hostActiveCount[host] = hostActiveCount[host] or 0
    if hostActiveCount[host] >= MAX_UNITS_PER_HOST then
        -- queue on that host
        pendingQueue[host] = pendingQueue[host] or {}
        table.insert(pendingQueue[host], unit)
        unit.status = 'queued_on_host'
        print(('[leo_ai_units] Host %s reached max (%d). Queued unit %d for incident %s'):format(tostring(host), hostActiveCount[host], unit.unit_id, tostring(unit.incident_id)))
        return unit.unit_id
    end

    -- Ask the host client to spawn the unit
    print(('[leo_ai_units] Requesting spawn of unit %d on host %s (coords %.1f, %.1f, %.1f)'):format(unit.unit_id, tostring(host), unit.coords.x, unit.coords.y, unit.coords.z))
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
        print('Usage: leo_assign <incident_id> [x] [y] [z]')
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

    local incident = { incident_id = incident_id, coords = template.spawnCoords }
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

    -- update counters
    hostActiveCount[src] = (hostActiveCount[src] or 0) + 1
    incidentActiveCount[unit.incident_id] = (incidentActiveCount[unit.incident_id] or 0) + 1

    print(('[leo_ai_units] Unit %d spawned by host %s (netId=%s). hostActive=%d incidentActive=%d'):
        format(unit.unit_id, tostring(src), tostring(unit.netId), hostActiveCount[src], incidentActiveCount[unit.incident_id]))

    -- Persist unit to DB if available
    if hasOx then
        local insertSql = "INSERT INTO incidents_units (unit_id, incident_id, unit_type, ped_model, vehicle_model, host, net_id, status, spawned_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW())"
        local params = { unit.unit_id, unit.incident_id, unit.unit_type, unit.pedModel, unit.vehicleModel, unit.host, tostring(unit.netId), unit.status }

        if exports['oxmysql'].insert then
            exports.oxmysql:insert(insertSql, params, function(insertId)
                if insertId and tonumber(insertId) then
                    unit.db_id = tonumber(insertId)
                    print(('[leo_ai_units] Persisted unit %d as db id %s'):format(unit.unit_id, tostring(unit.db_id)))
                else
                    print('[leo_ai_units] oxmysql.insert returned no insert id for unit')
                end
            end)
        else
            exports.oxmysql:execute(insertSql, params, function(result)
                local insertId = nil
                if type(result) == 'number' then
                    insertId = result
                elseif result and result.insertId then
                    insertId = result.insertId
                end
                if insertId then
                    unit.db_id = insertId
                    print(('[leo_ai_units] Persisted unit %d as db id %s'):format(unit.unit_id, tostring(unit.db_id)))
                else
                    print('[leo_ai_units] Failed to determine DB insert id for unit')
                end
            end)
        end
    end

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

    -- update counters
    local host = unit.host
    if host then
        hostActiveCount[host] = math.max(0, (hostActiveCount[host] or 1) - 1)
    end
    incidentActiveCount[unit.incident_id] = math.max(0, (incidentActiveCount[unit.incident_id] or 1) - 1)

    -- persist despawn time if DB id present
    if hasOx and unit.db_id then
        local updateSql = "UPDATE incidents_units SET status = ?, despawned_at = NOW() WHERE id = ?"
        exports.oxmysql:execute(updateSql, { unit.status, unit.db_id }, function()
            print(('[leo_ai_units] Updated DB record for unit %d (db id=%s) as despawned'):format(unit.unit_id, tostring(unit.db_id)))
        end)
    end

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

    -- If host has a pending queue, dispatch the next queued unit
    if host and pendingQueue[host] and #pendingQueue[host] > 0 then
        local nextUnit = table.remove(pendingQueue[host], 1)
        if nextUnit then
            print(('[leo_ai_units] Dispatching queued unit %d on host %s'):format(nextUnit.unit_id, tostring(host)))
            TriggerClientEvent('leo_ai_units:spawnRequest', host, nextUnit)
        end
    end
end)

-- Allow clients/MDT to request recent units for an incident (DB-backed if available)
RegisterNetEvent('leo_ai_units:requestUnits')
AddEventHandler('leo_ai_units:requestUnits', function(incident_id)
    local src = source
    if hasOx then
        local sql = "SELECT id AS db_id, unit_id, incident_id, unit_type, ped_model, vehicle_model, host, net_id, status, spawned_at, despawned_at FROM incidents_units WHERE incident_id = ? ORDER BY spawned_at DESC LIMIT 100"
        exports.oxmysql:execute(sql, { incident_id }, function(results)
            if results then
                TriggerClientEvent('leo_ai_units:recentUnits', src, results)
                return
            end
            -- fallback to in-memory
            TriggerClientEvent('leo_ai_units:recentUnits', src, incidentToUnits[incident_id] or {})
        end)
    else
        -- return in-memory list
        local list = {}
        local ids = incidentToUnits[incident_id] or {}
        for _, uid in ipairs(ids) do
            local u = activeUnits[uid]
            if u then table.insert(list, u) end
        end
        TriggerClientEvent('leo_ai_units:recentUnits', src, list)
    end
end)

-- Export simple helper for server code to request assignment
exports('assignUnitToIncident', assignUnitToIncident)

print('[leo_ai_units] Server with DB persistence loaded')
