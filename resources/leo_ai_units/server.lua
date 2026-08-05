-- resources/leo_ai_units/server.lua
-- Server-side AI unit manager with spawn limits, queuing, DB persistence, host failover and persistent queued assignments.
-- Maintains unit state and requests a client host to spawn AI peds/vehicles.

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

-- Persist a queued unit into DB and set unit.db_id
local function persistQueuedUnit(unit)
    if not hasOx then return end
    local insertSql = "INSERT INTO incidents_units (unit_id, incident_id, unit_type, ped_model, vehicle_model, host, status) VALUES (?, ?, ?, ?, ?, ?, ?)"
    local params = { unit.unit_id, unit.incident_id, unit.unit_type, unit.pedModel, unit.vehicleModel, unit.host, unit.status }
    if exports['oxmysql'].insert then
        exports.oxmysql:insert(insertSql, params, function(insertId)
            if insertId and tonumber(insertId) then
                unit.db_id = tonumber(insertId)
                print(('[leo_ai_units] Persisted queued unit %d as db id %s'):format(unit.unit_id, tostring(unit.db_id)))
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
                print(('[leo_ai_units] Persisted queued unit %d as db id %s'):format(unit.unit_id, tostring(unit.db_id)))
            end
        end)
    end
end

-- Update DB record when a unit is spawned (set net_id, status, spawned_at, host)
local function markUnitSpawnedInDB(unit)
    if not hasOx or not unit.db_id then return end
    local sql = "UPDATE incidents_units SET net_id = ?, status = ?, spawned_at = NOW(), host = ? WHERE id = ?"
    exports.oxmysql:execute(sql, { tostring(unit.netId), unit.status, unit.host, unit.db_id }, function()
        print(('[leo_ai_units] Updated DB for spawned unit %d (db id=%s)'):format(unit.unit_id, tostring(unit.db_id)))
    end)
end

-- Update DB record when a unit is reassigned or queued
local function updateUnitHostStatusInDB(unit)
    if not hasOx or not unit.db_id then return end
    local sql = "UPDATE incidents_units SET host = ?, status = ? WHERE id = ?"
    exports.oxmysql:execute(sql, { unit.host, unit.status, unit.db_id }, function()
        print(('[leo_ai_units] Updated DB host/status for unit %d (db id=%s)'):format(unit.unit_id, tostring(unit.db_id)))
    end)
end

-- Update DB when unit is despawned
local function markUnitDespawnedInDB(unit)
    if not hasOx or not unit.db_id then return end
    local sql = "UPDATE incidents_units SET status = ?, despawned_at = NOW() WHERE id = ?"
    exports.oxmysql:execute(sql, { unit.status, unit.db_id }, function()
        print(('[leo_ai_units] Marked DB unit %d (db id=%s) as despawned'):format(unit.unit_id, tostring(unit.db_id)))
    end)
end

-- Ensure DB table exists on resource start and load persistent queued assignments
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
        -- load max unit_id to continue counters
        exports.oxmysql:execute("SELECT COALESCE(MAX(unit_id), 0) AS max_unit FROM incidents_units", {}, function(res)
            if res and res[1] and res[1].max_unit then
                unitCounter = tonumber(res[1].max_unit) or 0
                print(('[leo_ai_units] Initialized unitCounter from DB: %d'):format(unitCounter))
            end

            -- load queued/reassignable units and restore in-memory queues
            local qsql = "SELECT id, unit_id, incident_id, unit_type, ped_model, vehicle_model, host, net_id, status FROM incidents_units WHERE status IN ('queued','queued_on_host','reassigned','host_lost') ORDER BY id ASC"
            exports.oxmysql:execute(qsql, {}, function(rows)
                if rows and #rows > 0 then
                    print(('[leo_ai_units] Restoring %d queued/reassignable units from DB'):format(#rows))
                    for _, r in ipairs(rows) do
                        local u = {
                            unit_id = tonumber(r.unit_id) or 0,
                            incident_id = tonumber(r.incident_id) or 0,
                            unit_type = r.unit_type,
                            pedModel = r.ped_model,
                            vehicleModel = r.vehicle_model,
                            host = r.host and tonumber(r.host) or nil,
                            netId = r.net_id,
                            status = r.status or 'queued',
                            db_id = tonumber(r.id)
                        }
                        -- store in activeUnits and incidentToUnits so other logic can reference
                        activeUnits[u.unit_id] = u
                        incidentToUnits[u.incident_id] = incidentToUnits[u.incident_id] or {}
                        table.insert(incidentToUnits[u.incident_id], u.unit_id)

                        -- Decide whether to queue or dispatch immediately
                        if u.host then
                            hostActiveCount[u.host] = hostActiveCount[u.host] or 0
                            if hostActiveCount[u.host] >= MAX_UNITS_PER_HOST then
                                pendingQueue[u.host] = pendingQueue[u.host] or {}
                                table.insert(pendingQueue[u.host], u)
                                u.status = 'queued_on_host'
                            else
                                -- dispatch
                                TriggerClientEvent('leo_ai_units:spawnRequest', u.host, u)
                                u.status = 'reassigned'
                            end
                        else
                            -- assign to best available host
                            local chosen = chooseHostForIncident({ incident_id = u.incident_id, coords = nil }, nil, nil)
                            if chosen then
                                hostActiveCount[chosen] = hostActiveCount[chosen] or 0
                                if hostActiveCount[chosen] >= MAX_UNITS_PER_HOST then
                                    pendingQueue[chosen] = pendingQueue[chosen] or {}
                                    table.insert(pendingQueue[chosen], u)
                                    u.status = 'queued_on_host'
                                    u.host = chosen
                                else
                                    TriggerClientEvent('leo_ai_units:spawnRequest', chosen, u)
                                    u.status = 'reassigned'
                                    u.host = chosen
                                end
                            else
                                u.status = 'orphaned'
                                print(('[leo_ai_units] Could not find host to restore unit %d'):format(u.unit_id))
                            end
                        end

                        -- update DB with possibly new host/status
                        updateUnitHostStatusInDB(u)
                    end
                end
            end)
        end)
    end)
end)

-- Choose host function (reuse existing logic) --------------------------------------------------
local function chooseHostForIncident(incident, fallbackCoords, excludeHost)
    local players = GetPlayers()
    if not players or #players == 0 then return nil end

    for _, pid in ipairs(players) do
        local player = tonumber(pid)
        if excludeHost and player == excludeHost then goto continue1 end
        local ok, ply = pcall(function() return QBCore.Functions.GetPlayer(player) end)
        if ok and ply and ply.PlayerData and ply.PlayerData.job and ply.PlayerData.job.name == 'ai_host' then
            return player
        end
        ::continue1::
    end

    local tx, ty, tz = nil, nil, nil
    if incident and incident.coords and incident.coords.x then
        tx, ty, tz = incident.coords.x, incident.coords.y, incident.coords.z
    elseif fallbackCoords and fallbackCoords.x then
        tx, ty, tz = fallbackCoords.x, fallbackCoords.y, fallbackCoords.z
    end

    if tx then
        local best, bestDist = nil, math.huge
        for _, pid in ipairs(players) do
            local player = tonumber(pid)
            if excludeHost and player == excludeHost then goto continue2 end
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
            ::continue2::
        end
        if best then return best end
    end

    for _, pid in ipairs(players) do
        local player = tonumber(pid)
        if excludeHost and player == excludeHost then goto continue3 end
        return player
        ::continue3::
    end

    return nil
end

-- Reassign a unit to a different host (preserves unit_id)
local function reassignUnit(unit, excludeHost)
    if not unit then return false end
    local newHost = chooseHostForIncident({ incident_id = unit.incident_id, coords = unit.coords }, nil, excludeHost)
    if not newHost then
        unit.status = 'orphaned'
        if hasOx and unit.db_id then
            exports.oxmysql:execute("UPDATE incidents_units SET status = ? WHERE id = ?", { unit.status, unit.db_id })
        end
        return false
    end

    unit.host = newHost
    hostActiveCount[newHost] = hostActiveCount[newHost] or 0
    local activeForIncident = incidentActiveCount[unit.incident_id] or 0
    local pendingForIncident = countPendingForIncident(unit.incident_id)
    if hostActiveCount[newHost] >= MAX_UNITS_PER_HOST or (activeForIncident + pendingForIncident) >= MAX_UNITS_PER_INCIDENT then
        pendingQueue[newHost] = pendingQueue[newHost] or {}
        table.insert(pendingQueue[newHost], unit)
        unit.status = 'queued_on_host'
        updateUnitHostStatusInDB(unit)
        return true
    end

    TriggerClientEvent('leo_ai_units:spawnRequest', newHost, unit)
    unit.status = 'reassigned'
    updateUnitHostStatusInDB(unit)
    return true
end

-- Reassign all units and queued assignments for a host that disconnected
local function reassignUnitsFromHost(host)
    print(('[leo_ai_units] Host %s disconnected — reassigning its units and queued tasks'):format(tostring(host)))

    local queued = pendingQueue[host] or {}
    pendingQueue[host] = nil
    for _, unit in ipairs(queued) do
        reassignUnit(unit, host)
    end

    for uid, unit in pairs(activeUnits) do
        if unit.host == host then
            hostActiveCount[host] = 0
            if unit.status == 'enroute' or unit.status == 'queued_on_host' or unit.status == 'reassigned' then
                unit.status = 'host_lost'
                local ok = reassignUnit(unit, host)
                if not ok then
                    print(('[leo_ai_units] Could not reassign active unit %d; marked orphaned'):format(uid))
                end
            end
        end
    end
end

-- Assign a single unit to an incident using a template
local function assignUnitToIncident(incident, template)
    local host = chooseHostForIncident(incident, template and template.spawnCoords)
    if not host then
        print('[leo_ai_units] No host players available to spawn AI')
        return nil
    end

    local incident_id = incident.incident_id or incident.id or 0
    local activeForIncident = incidentActiveCount[incident_id] or 0
    local pendingForIncident = countPendingForIncident(incident_id)
    if (activeForIncident + pendingForIncident) >= MAX_UNITS_PER_INCIDENT then
        print(('[leo_ai_units] Incident %s has reached max units'):
            format(tostring(incident_id)))
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
        pendingQueue[host] = pendingQueue[host] or {}
        table.insert(pendingQueue[host], unit)
        unit.status = 'queued_on_host'
        -- persist queued unit
        persistQueuedUnit(unit)
        return unit.unit_id
    end

    -- persist queued unit before requesting spawn to ensure recovery if host drops
    persistQueuedUnit(unit)

    -- Ask the host client to spawn the unit
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

    -- persist spawn in DB if queued previously
    if unit.db_id then
        markUnitSpawnedInDB(unit)
    else
        -- if it wasn't persisted earlier (no DB row), insert now
        if hasOx then
            local insertSql = "INSERT INTO incidents_units (unit_id, incident_id, unit_type, ped_model, vehicle_model, host, net_id, status, spawned_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW())"
            local params = { unit.unit_id, unit.incident_id, unit.unit_type, unit.pedModel, unit.vehicleModel, unit.host, tostring(unit.netId), unit.status }
            if exports['oxmysql'].insert then
                exports.oxmysql:insert(insertSql, params, function(insertId)
                    if insertId and tonumber(insertId) then
                        unit.db_id = tonumber(insertId)
                        print(('[leo_ai_units] Persisted spawned unit %d as db id %s'):format(unit.unit_id, tostring(unit.db_id)))
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
                        print(('[leo_ai_units] Persisted spawned unit %d as db id %s'):format(unit.unit_id, tostring(unit.db_id)))
                    end
                end)
            end
        end
    end

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

    local host = unit.host
    if host then
        hostActiveCount[host] = math.max(0, (hostActiveCount[host] or 1) - 1)
    end
    incidentActiveCount[unit.incident_id] = math.max(0, (incidentActiveCount[unit.incident_id] or 1) - 1)

    if unit.db_id then
        markUnitDespawnedInDB(unit)
    end

    activeUnits[data.unit_id] = nil
    local list = incidentToUnits[unit.incident_id]
    if list then
        for i = #list, 1, -1 do
            if list[i] == data.unit_id then
                table.remove(list, i)
            end
        end
    end

    if host and pendingQueue[host] and #pendingQueue[host] > 0 then
        local nextUnit = table.remove(pendingQueue[host], 1)
        if nextUnit then
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
            local list = {}
            local ids = incidentToUnits[incident_id] or {}
            for _, uid in ipairs(ids) do
                local u = activeUnits[uid]
                if u then table.insert(list, u) end
            end
            TriggerClientEvent('leo_ai_units:recentUnits', src, list)
        end)
    else
        local list = {}
        local ids = incidentToUnits[incident_id] or {}
        for _, uid in ipairs(ids) do
            local u = activeUnits[uid]
            if u then table.insert(list, u) end
        end
        TriggerClientEvent('leo_ai_units:recentUnits', src, list)
    end
end)

-- Player disconnect handler: reassign queued & active units owned by the disconnected host
AddEventHandler('playerDropped', function(reason)
    local src = source
    if not src then return end
    reassignUnitsFromHost(src)
    hostActiveCount[src] = 0
    pendingQueue[src] = nil
end)

-- Export simple helper for server code to request assignment
exports('assignUnitToIncident', assignUnitToIncident)

print('[leo_ai_units] Server with persistent queued assignments loaded')
