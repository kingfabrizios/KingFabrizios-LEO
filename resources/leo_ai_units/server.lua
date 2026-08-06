-- resources/leo_ai_units/server.lua
-- AI unit manager: persistent queued assignments, heartbeats, graceful handoff (atomic accept/ack), MDT host controls and alerts

local activeUnits = {}
local unitCounter = 0
local incidentToUnits = {}
local incidentsStore = {}
local QBCore = exports['qb-core']:GetCoreObject()

-- DB availability
local hasOx = exports['oxmysql'] ~= nil

-- Limits & timeouts
local MAX_UNITS_PER_HOST = 4
local MAX_UNITS_PER_INCIDENT = 6
local HEARTBEAT_INTERVAL = 5000
local HEARTBEAT_WARN_SEC = 12
local HEARTBEAT_TIMEOUT_SEC = 22
local HANDOFF_ACCEPT_TIMEOUT = 15
local QUEUED_ALERT_THRESHOLD = 5

-- permission: which jobs can control MDT host operations
local DISPATCHER_JOBS = { police = true, dispatch = true } -- adjust as needed

-- runtime counters & queues
local hostActiveCount = {}
local incidentActiveCount = {}
local pendingQueue = {}
local lastHeartbeat = {}
local lastPosition = {}

-- host maintenance/whitelist
local hostMaintenance = {}
local allowedHosts = {}

-- pending handoffs: handoffId -> { units = {unit}, oldHost, newHost, expiry, accepted = {unit_id=true}, timer }
local pendingHandoffs = {}
local crypto = nil

-- small helper to generate a handoff id
local function genHandoffId()
    local t = tostring(os.time()) .. tostring(math.random(1000,9999))
    return t
end

local function isDispatcher(src)
    if not src or src == 0 then return false end
    local ok, ply = pcall(function() return QBCore.Functions.GetPlayer(src) end)
    if not ok or not ply or not ply.PlayerData or not ply.PlayerData.job then return false end
    local job = ply.PlayerData.job.name
    return DISPATCHER_JOBS[job] == true
end

local function countPendingForIncident(incident_id)
    local c = 0
    for _, list in pairs(pendingQueue) do
        for _, u in ipairs(list) do
            if u.incident_id == incident_id then c = c + 1 end
        end
    end
    return c
end

-- DB helpers (persist/update) - same as earlier implementations
local function persistQueuedUnit(unit)
    if not hasOx then return end
    local insertSql = "INSERT INTO incidents_units (unit_id, incident_id, unit_type, ped_model, vehicle_model, host, status) VALUES (?, ?, ?, ?, ?, ?, ?)"
    local params = { unit.unit_id, unit.incident_id, unit.unit_type, unit.pedModel, unit.vehicleModel, unit.host, unit.status }
    if exports['oxmysql'].insert then
        exports.oxmysql:insert(insertSql, params, function(insertId)
            if insertId and tonumber(insertId) then
                unit.db_id = tonumber(insertId)
            end
        end)
    else
        exports.oxmysql:execute(insertSql, params, function(result)
            local insertId = nil
            if type(result) == 'number' then insertId = result
            elseif result and result.insertId then insertId = result.insertId end
            if insertId then unit.db_id = insertId end
        end)
    end
end

local function updateUnitHostStatusInDB(unit)
    if not hasOx or not unit.db_id then return end
    local sql = "UPDATE incidents_units SET host = ?, status = ? WHERE id = ?"
    exports.oxmysql:execute(sql, { unit.host, unit.status, unit.db_id })
end

local function markUnitSpawnedInDB(unit)
    if not hasOx or not unit.db_id then return end
    local sql = "UPDATE incidents_units SET net_id = ?, status = ?, spawned_at = NOW(), host = ? WHERE id = ?"
    exports.oxmysql:execute(sql, { tostring(unit.netId), unit.status, unit.host, unit.db_id })
end

local function markUnitDespawnedInDB(unit)
    if not hasOx or not unit.db_id then return end
    local sql = "UPDATE incidents_units SET status = ?, despawned_at = NOW() WHERE id = ?"
    exports.oxmysql:execute(sql, { unit.status, unit.db_id })
end

-- Utility: is host selectable
local function isHostSelectable(host)
    if hostMaintenance[host] then return false end
    if next(allowedHosts) ~= nil then
        return allowedHosts[host] == true
    end
    return true
end

-- alert emitter: informs MDT clients
local function emitHostAlert(alert)
    TriggerClientEvent('leo_ai_units:hostAlert', -1, alert)
end

-- chooseHostForIncident reuse (respect maintenance/whitelist)
local function chooseHostForIncident(incident, fallbackCoords, excludeHost)
    local players = GetPlayers()
    if not players or #players == 0 then return nil end

    for _, pid in ipairs(players) do
        local player = tonumber(pid)
        if excludeHost and player == excludeHost then goto continue1 end
        if not isHostSelectable(player) then goto continue1 end
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
            if not isHostSelectable(player) then goto continue2 end
            local ped = GetPlayerPed(player)
            if ped and ped > 0 then
                local px, py, pz = table.unpack(GetEntityCoords(ped, true))
                local dx = px - tx
                local dy = py - ty
                local dz = (pz or 0.0) - (tz or 0.0)
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist < bestDist then bestDist = dist; best = player end
            end
            ::continue2::
        end
        if best then return best end
    end

    for _, pid in ipairs(players) do
        local player = tonumber(pid)
        if excludeHost and player == excludeHost then goto continue3 end
        if not isHostSelectable(player) then goto continue3 end
        return player
        ::continue3::
    end

    return nil
end

-- reassign logic reused
local function reassignUnit(unit, excludeHost)
    if not unit then return false end
    local newHost = chooseHostForIncident({ incident_id = unit.incident_id, coords = unit.coords }, nil, excludeHost)
    if not newHost then
        unit.status = 'orphaned'
        if hasOx and unit.db_id then exports.oxmysql:execute("UPDATE incidents_units SET status = ? WHERE id = ?", { unit.status, unit.db_id }) end
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

-- pending handoff handling
local function startHandoff(oldHost, units)
    local handoffId = genHandoffId()
    local entry = { units = {}, oldHost = oldHost, newHost = nil, expiry = os.time() + HANDOFF_ACCEPT_TIMEOUT, accepted = {}, timer = nil }

    for _, u in ipairs(units) do
        table.insert(entry.units, u)
    end

    pendingHandoffs[handoffId] = entry

    -- choose a host per unit and send spawnRequest with handoff metadata
    for _, unit in ipairs(entry.units) do
        local newHost = chooseHostForIncident({ incident_id = unit.incident_id, coords = unit.coords }, nil, oldHost)
        if newHost then
            unit.handoffId = handoffId
            unit.handoffFrom = oldHost
            unit.handoffTo = newHost
            TriggerClientEvent('leo_ai_units:spawnRequest', newHost, unit)
            entry.newHost = newHost -- note last
        else
            -- no host available: mark orphaned
            unit.status = 'orphaned'
            if hasOx and unit.db_id then exports.oxmysql:execute("UPDATE incidents_units SET status = ? WHERE id = ?", { unit.status, unit.db_id }) end
        end
    end

    -- start timeout watcher
    Citizen.CreateThread(function()
        local id = handoffId
        while pendingHandoffs[id] do
            if os.time() >= pendingHandoffs[id].expiry then
                local p = pendingHandoffs[id]
                -- handle unaccepted units
                for _, u in ipairs(p.units) do
                    if not p.accepted[u.unit_id] then
                        -- attempt forced reassign (excluding oldHost)
                        reassignUnit(u, p.oldHost)
                    end
                end
                pendingHandoffs[id] = nil
                break
            end
            Citizen.Wait(1000)
        end
    end)

    return handoffId
end

-- accept handler: called when new host reports it accepted/claimed a unit (client-side will trigger)
RegisterNetEvent('leo_ai_units:handoffAccept')
AddEventHandler('leo_ai_units:handoffAccept', function(data)
    local src = source
    if not data or not data.handoffId then return end
    local hid = data.handoffId
    local unit_id = tonumber(data.unit_id)
    local p = pendingHandoffs[hid]
    if not p then return end
    -- record acceptance
    p.accepted[unit_id] = true

    -- update unit record
    local unit = activeUnits[unit_id]
    if unit then
        unit.host = src
        unit.status = 'reassigned'
        updateUnitHostStatusInDB(unit)
    end

    -- if all units accepted, instruct old host to cleanup
    local allAccepted = true
    for _, u in ipairs(p.units) do if not p.accepted[u.unit_id] then allAccepted = false; break end end
    if allAccepted then
        -- notify old host about completion for these units
        local ids = {}
        for _, u in ipairs(p.units) do table.insert(ids, u.unit_id) end
        TriggerClientEvent('leo_ai_units:completeHandoff', p.oldHost, { unit_ids = ids })
        pendingHandoffs[hid] = nil
    end
end)

-- server handlers: assignUnit, clientSpawned, clientDespawn, clientStatus (reuse earlier code)
RegisterNetEvent('leo_ai_units:assign')
AddEventHandler('leo_ai_units:assign', function(incident, template)
    -- (reuse assignUnitToIncident implementation)
    local host = chooseHostForIncident(incident, template and template.spawnCoords)
    if not host then print('[leo_ai_units] No host players available to spawn AI'); return end
    local incident_id = incident.incident_id or incident.id or 0
    local activeForIncident = incidentActiveCount[incident_id] or 0
    local pendingForIncident = countPendingForIncident(incident_id)
    if (activeForIncident + pendingForIncident) >= MAX_UNITS_PER_INCIDENT then print(('[leo_ai_units] Incident %s has reached max units'):format(tostring(incident_id))); return end
    unitCounter = unitCounter + 1
    local unit = { unit_id = unitCounter, incident_id = incident_id, unit_type = template.unit_type or 'unit', pedModel = template.pedModel, vehicleModel = template.vehicleModel, coords = template.spawnCoords or template.coords or (incident and incident.coords) or { x = 0.0, y = 0.0, z = 0.0 }, behavior = template.behavior or 'drive_to_scene', status = 'queued', host = host }
    activeUnits[unit.unit_id] = unit
    incidentToUnits[unit.incident_id] = incidentToUnits[unit.incident_id] or {}
    table.insert(incidentToUnits[unit.incident_id], unit.unit_id)
    hostActiveCount[host] = hostActiveCount[host] or 0
    if hostActiveCount[host] >= MAX_UNITS_PER_HOST then pendingQueue[host] = pendingQueue[host] or {}; table.insert(pendingQueue[host], unit); unit.status = 'queued_on_host'; persistQueuedUnit(unit); return unit.unit_id end
    persistQueuedUnit(unit)
    TriggerClientEvent('leo_ai_units:spawnRequest', host, unit)
    return unit.unit_id
end)

RegisterNetEvent('leo_ai_units:clientSpawned')
AddEventHandler('leo_ai_units:clientSpawned', function(data)
    local src = source
    if not data or not data.unit_id then return end
    local unit = activeUnits[data.unit_id]
    if not unit then return end
    unit.netId = data.netId
    unit.entityType = data.entityType
    unit.status = 'enroute'
    unit.host = src
    hostActiveCount[src] = (hostActiveCount[src] or 0) + 1
    incidentActiveCount[unit.incident_id] = (incidentActiveCount[unit.incident_id] or 0) + 1
    if unit.db_id then markUnitSpawnedInDB(unit) end
    TriggerClientEvent('leo_dispatch:unitUpdate', -1, unit)
    -- If this spawn was part of a handoff, treat it as acceptance as well
    if data.handoffId then
        TriggerEvent('leo_ai_units:handoffAccept', { unit_id = data.unit_id, handoffId = data.handoffId })
    end
end)

RegisterNetEvent('leo_ai_units:clientDespawn')
AddEventHandler('leo_ai_units:clientDespawn', function(data)
    if not data or not data.unit_id then return end
    local unit = activeUnits[data.unit_id]
    if not unit then return end
    unit.status = 'despawned'
    unit.despawned_at = os.time()
    TriggerClientEvent('leo_dispatch:unitUpdate', -1, unit)
    local host = unit.host
    if host then hostActiveCount[host] = math.max(0, (hostActiveCount[host] or 1) - 1) end
    incidentActiveCount[unit.incident_id] = math.max(0, (incidentActiveCount[unit.incident_id] or 1) - 1)
    if unit.db_id then markUnitDespawnedInDB(unit) end
    activeUnits[data.unit_id] = nil
    local list = incidentToUnits[unit.incident_id]
    if list then for i = #list, 1, -1 do if list[i] == data.unit_id then table.remove(list, i) end end end
    if host and pendingQueue[host] and #pendingQueue[host] > 0 then local nextUnit = table.remove(pendingQueue[host], 1); if nextUnit then TriggerClientEvent('leo_ai_units:spawnRequest', host, nextUnit) end end
end)

-- Host heartbeat handler
RegisterNetEvent('leo_ai_units:heartbeat')
AddEventHandler('leo_ai_units:heartbeat', function(data)
    local src = source
    if not src then return end
    lastHeartbeat[src] = os.time()
    if data then
        if data.activeCount then hostActiveCount[src] = tonumber(data.activeCount) or hostActiveCount[src] or 0 end
        if data.position then lastPosition[src] = data.position end
    end
end)

-- prepareHandoff request from server -> host triggers host to send handoffReady; host will call handoffReady server event
RegisterNetEvent('leo_ai_units:handoffReady')
AddEventHandler('leo_ai_units:handoffReady', function(data)
    -- This event is now used by clients to send their list when prepared. The earlier flow started handoff on server when client signaled prepare.
    local src = source
    if not src or not data or not data.units then return end
    -- Start an atomic handoff for these units
    startHandoff(src, data.units)
end)

-- MDT: requestHosts (no auth required to view)
RegisterNetEvent('leo_ai_units:requestHosts')
AddEventHandler('leo_ai_units:requestHosts', function()
    local src = source
    if not src then return end
    local hosts = {}
    local players = GetPlayers() or {}
    for _, pid in ipairs(players) do
        local player = tonumber(pid)
        local hb = lastHeartbeat[player]
        local age = nil
        if hb then age = os.time() - hb end
        local active = hostActiveCount[player] or 0
        local queued = pendingQueue[player] and #pendingQueue[player] or 0
        local ok, ply = pcall(function() return QBCore.Functions.GetPlayer(player) end)
        local isDedicated = false
        local name = tostring(player)
        if ok and ply and ply.PlayerData and ply.PlayerData.job and ply.PlayerData.job.name == 'ai_host' then
            isDedicated = true
            name = (ply.PlayerData.charinfo and (ply.PlayerData.charinfo.firstname .. ' ' .. ply.PlayerData.charinfo.lastname)) or name
        elseif ok and ply and ply.PlayerData and ply.PlayerData.charinfo then
            name = ply.PlayerData.charinfo.firstname .. ' ' .. ply.PlayerData.charinfo.lastname
        end
        table.insert(hosts, { hostId = player, name = name, isDedicated = isDedicated, lastHeartbeat = hb, heartbeatAge = age, activeCount = active, queuedCount = queued, position = lastPosition[player] })
        -- emit alerts if thresholds breached
        if queued >= QUEUED_ALERT_THRESHOLD then emitHostAlert({ type = 'queued_high', host = player, queued = queued }) end
        if age and age >= HEARTBEAT_WARN_SEC then emitHostAlert({ type = 'stale', host = player, age = age }) end
    end
    TriggerClientEvent('leo_ai_units:hostsStatus', src, hosts)
end)

-- MDT: request host detail (permission-protected)
RegisterNetEvent('leo_ai_units:requestHostDetail')
AddEventHandler('leo_ai_units:requestHostDetail', function(hostId)
    local src = source
    if not src then return end
    if not isDispatcher(src) then
        TriggerClientEvent('leo_ai_units:permissionDenied', src, { action = 'requestHostDetail' })
        return
    end
    local host = tonumber(hostId)
    local list = {}
    for uid, u in pairs(activeUnits) do if u.host == host then table.insert(list, u) end end
    if pendingQueue[host] then for _, u in ipairs(pendingQueue[host]) do table.insert(list, u) end end
    TriggerClientEvent('leo_ai_units:hostDetail', src, { hostId = host, units = list, position = lastPosition[host], heartbeat = lastHeartbeat[host], activeCount = hostActiveCount[host] or 0, queuedCount = pendingQueue[host] and #pendingQueue[host] or 0 })
end)

-- MDT: set host maintenance (permission-protected)
RegisterNetEvent('leo_ai_units:setHostMaintenance')
AddEventHandler('leo_ai_units:setHostMaintenance', function(hostId, enable)
    local src = source
    if not src then return end
    if not isDispatcher(src) then
        TriggerClientEvent('leo_ai_units:permissionDenied', src, { action = 'setHostMaintenance' })
        return
    end
    local host = tonumber(hostId)
    hostMaintenance[host] = enable and true or nil
    TriggerClientEvent('leo_ai_units:hostsStatusUpdated', -1, { host = host, maintenance = hostMaintenance[host] })
end)

-- MDT: set host whitelist (permission-protected)
RegisterNetEvent('leo_ai_units:setHostWhitelist')
AddEventHandler('leo_ai_units:setHostWhitelist', function(hostId, enable)
    local src = source
    if not src then return end
    if not isDispatcher(src) then
        TriggerClientEvent('leo_ai_units:permissionDenied', src, { action = 'setHostWhitelist' })
        return
    end
    local host = tonumber(hostId)
    if enable then allowedHosts[host] = true else allowedHosts[host] = nil end
end)

-- Player disconnect handler
AddEventHandler('playerDropped', function(reason)
    local src = source
    if not src then return end
    -- if host disconnected while a handoff for them is pending, force reassign
    for hid, p in pairs(pendingHandoffs) do
        if p.oldHost == src then
            for _, u in ipairs(p.units) do if not p.accepted[u.unit_id] then reassignUnit(u, src) end end
            pendingHandoffs[hid] = nil
        end
    end
    -- reassign units normally
    for uid, unit in pairs(activeUnits) do if unit.host == src then unit.status = 'host_lost'; reassignUnit(unit, src) end end
    hostActiveCount[src] = 0
    pendingQueue[src] = nil
    lastHeartbeat[src] = nil
    lastPosition[src] = nil
end)

-- Background: heartbeat monitor + alerts
Citizen.CreateThread(function()
    while true do
        local now = os.time()
        for host, t in pairs(lastHeartbeat) do
            local age = now - t
            if age >= HEARTBEAT_TIMEOUT_SEC then
                emitHostAlert({ type = 'timeout', host = host, age = age })
                -- force reassign
                for uid, unit in pairs(activeUnits) do if unit.host == host then reassignUnit(unit, host) end end
                hostActiveCount[host] = 0
                pendingQueue[host] = nil
                lastHeartbeat[host] = nil
            elseif age >= HEARTBEAT_WARN_SEC then
                emitHostAlert({ type = 'warn', host = host, age = age })
                TriggerClientEvent('leo_ai_units:prepareHandoff', host, {})
            end
        end
        Citizen.Wait(3000)
    end
end)

print('[leo_ai_units] Server hardened: permission checks and atomic handoff support loaded')
