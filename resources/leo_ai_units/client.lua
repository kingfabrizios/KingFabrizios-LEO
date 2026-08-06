-- resources/leo_ai_units/client.lua
-- Client-side AI host: listens for spawn requests and creates peds/vehicles locally with pooling.
-- Also sends periodic heartbeats and supports graceful handoff when requested by the server.

local QBCore = exports['qb-core']:GetCoreObject()
local spawnedEntities = {} -- unit_id -> { ped, veh, netId, inUse, modelPed, modelVeh }

-- Pool structures per model
local pool = {
    peds = {},   -- modelHash -> list of { ent = pedEntity, inUse = bool }
    vehs = {}
}

local MAX_POOL_PER_MODEL = 3 -- max pooled entities per model on this client
local HEARTBEAT_SEND_INTERVAL = 5000 -- ms

-- Helper: safe model loading
local function LoadModel(model)
    local mHash = type(model) == 'string' and GetHashKey(model) or model
    RequestModel(mHash)
    local timeout = 100
    while not HasModelLoaded(mHash) and timeout > 0 do
        Citizen.Wait(50)
        timeout = timeout - 1
    end
    return mHash
end

local function findFreePoolEntity(list)
    for i, e in ipairs(list) do
        if not e.inUse and DoesEntityExist(e.ent) then
            return i, e
        end
    end
    return nil, nil
end

local function createPooledPed(modelHash, x, y, z)
    local ped = CreatePed(4, modelHash, x, y, z + 0.5, 0.0, true, false)
    SetPedAsCop(ped, true)
    SetEntityAsMissionEntity(ped, true, true)
    return ped
end

local function createPooledVehicle(modelHash, x, y, z)
    local veh = CreateVehicle(modelHash, x, y, z + 0.5, 0.0, true, false)
    SetVehicleOnGroundProperly(veh)
    SetEntityAsMissionEntity(veh, true, true)
    return veh
end

local function freePooledEntity(ent)
    if not ent then return end
    if DoesEntityExist(ent) then
        SetEntityCoords(ent, 0.0, 0.0, -1000.0, false, false, false, true)
        if IsEntityAPed(ent) then
            ClearPedTasksImmediately(ent)
        elseif IsEntityAVehicle(ent) then
            SetEntityAsNoLongerNeeded(ent)
        end
    end
end

-- Count active spawned entities on this client
local function countActiveEntities()
    local c = 0
    for _, v in pairs(spawnedEntities) do
        if (v.ped and DoesEntityExist(v.ped)) or (v.veh and DoesEntityExist(v.veh)) then
            c = c + 1
        end
    end
    return c
end

-- Periodic heartbeat sender
Citizen.CreateThread(function()
    while true do
        local active = countActiveEntities()
        TriggerServerEvent('leo_ai_units:heartbeat', { activeCount = active })
        Citizen.Wait(HEARTBEAT_SEND_INTERVAL)
    end
end)

-- Handle server request to prepare handoff: send list of hosted units and positions
RegisterNetEvent('leo_ai_units:prepareHandoff')
AddEventHandler('leo_ai_units:prepareHandoff', function()
    -- Gather unit info
    local list = {}
    for uid, ent in pairs(spawnedEntities) do
        local entId = ent.ped and ent.ped or ent.veh
        if entId and DoesEntityExist(entId) then
            local px, py, pz = table.unpack(GetEntityCoords(entId, true))
            table.insert(list, { unit_id = uid, position = { x = px, y = py, z = pz } })
        else
            table.insert(list, { unit_id = uid, position = nil })
        end
    end

    -- Notify server we're ready to hand off these units
    TriggerServerEvent('leo_ai_units:handoffReady', { units = list })
end)

-- Server tells this host to complete handoff: cleanup local entities for the supplied unit_ids
RegisterNetEvent('leo_ai_units:completeHandoff')
AddEventHandler('leo_ai_units:completeHandoff', function(data)
    if not data or not data.unit_ids then return end
    for _, uid in ipairs(data.unit_ids) do
        local ent = spawnedEntities[tonumber(uid)]
        if ent then
            if ent.ped and DoesEntityExist(ent.ped) then
                DeletePed(ent.ped)
            end
            if ent.veh and DoesEntityExist(ent.veh) then
                DeleteVehicle(ent.veh)
            end
            spawnedEntities[uid] = nil
            -- Inform server we despawned (this also triggers queued dispatch server-side)
            TriggerServerEvent('leo_ai_units:clientDespawn', { unit_id = uid })
        end
    end
end)

-- Existing spawnRequest handler (pooling+spawn) -------------------------------------------------
RegisterNetEvent('leo_ai_units:spawnRequest')
AddEventHandler('leo_ai_units:spawnRequest', function(unit)
    if not unit or not unit.unit_id then return end
    -- (pooling/spawn logic unchanged from previous implementation)
    local pedHash = unit.pedModel and LoadModel(unit.pedModel) or nil
    local vehHash = unit.vehicleModel and LoadModel(unit.vehicleModel) or nil

    local x,y,z = unit.coords.x or unit.coords[1] or 0.0, unit.coords.y or unit.coords[2] or 0.0, unit.coords.z or unit.coords[3] or 0.0

    local createdPed = nil
    local createdVeh = nil

    if vehHash then
        pool.vehs[vehHash] = pool.vehs[vehHash] or {}
        local idx, entry = findFreePoolEntity(pool.vehs[vehHash])
        if entry then
            createdVeh = entry.ent
            pool.vehs[vehHash][idx].inUse = true
            SetEntityCoords(createdVeh, x, y, z + 0.5, false, false, false, true)
            SetVehicleOnGroundProperly(createdVeh)
        else
            if #pool.vehs[vehHash] < MAX_POOL_PER_MODEL then
                createdVeh = createPooledVehicle(vehHash, x, y, z)
                table.insert(pool.vehs[vehHash], { ent = createdVeh, inUse = true })
            else
                createdVeh = createPooledVehicle(vehHash, x, y, z)
            end
        end
    end

    if pedHash then
        pool.peds[pedHash] = pool.peds[pedHash] or {}
        local idx, entry = findFreePoolEntity(pool.peds[pedHash])
        if entry then
            createdPed = entry.ent
            pool.peds[pedHash][idx].inUse = true
            SetEntityCoords(createdPed, x, y, z + 0.5, false, false, false, true)
            ClearPedTasksImmediately(createdPed)
        else
            if #pool.peds[pedHash] < MAX_POOL_PER_MODEL then
                createdPed = createPooledPed(pedHash, x, y, z)
                table.insert(pool.peds[pedHash], { ent = createdPed, inUse = true })
            else
                createdPed = createPooledPed(pedHash, x, y, z)
            end
        end
    end

    if createdPed and createdVeh then
        TaskWarpPedIntoVehicle(createdPed, createdVeh, -1)
    elseif createdPed and not createdVeh then
        TaskGoStraightToCoord(createdPed, x, y, z, 1.0, -1, 0.0, 0.0)
    end

    local netId = nil
    local entityToNetwork = createdPed and createdPed or createdVeh
    if entityToNetwork and DoesEntityExist(entityToNetwork) then
        netId = NetworkGetNetworkIdFromEntity(entityToNetwork)
        SetNetworkIdCanMigrate(netId, true)
    end

    if netId then
        spawnedEntities[unit.unit_id] = { ped = createdPed, veh = createdVeh, netId = netId, modelPed = pedHash, modelVeh = vehHash }
        TriggerServerEvent('leo_ai_units:clientSpawned', { unit_id = unit.unit_id, netId = netId, entityType = (createdPed and 'ped' or 'vehicle') })

        Citizen.CreateThread(function()
            while spawnedEntities[unit.unit_id] do
                local ent = spawnedEntities[unit.unit_id]
                local entId = ent.ped and ent.ped or ent.veh
                if entId and DoesEntityExist(entId) then
                    local px,py,pz = table.unpack(GetEntityCoords(entId, true))
                    TriggerServerEvent('leo_ai_units:clientStatus', { unit_id = unit.unit_id, status = 'enroute', position = { x = px, y = py, z = pz } })
                else
                    TriggerServerEvent('leo_ai_units:clientDespawn', { unit_id = unit.unit_id })
                    spawnedEntities[unit.unit_id] = nil
                    break
                end
                Citizen.Wait(5000)
            end
        end)
    else
        print(('[leo_ai_units][client] Failed to network-spawn unit %d'):format(unit.unit_id))
    end
end)

-- Simple cleanup command for clients to free pooled spawned units locally
RegisterCommand('leo_despawn', function()
    for uid, ent in pairs(spawnedEntities) do
        if ent.ped and DoesEntityExist(ent.ped) then
            local model = ent.modelPed
            if model and pool.peds[model] then
                for i, e in ipairs(pool.peds[model]) do
                    if e.ent == ent.ped then
                        e.inUse = false
                        freePooledEntity(e.ent)
                        break
                    end
                end
            else
                DeletePed(ent.ped)
            end
        end
        if ent.veh and DoesEntityExist(ent.veh) then
            local model = ent.modelVeh
            if model and pool.vehs[model] then
                for i, e in ipairs(pool.vehs[model]) do
                    if e.ent == ent.veh then
                        e.inUse = false
                        freePooledEntity(e.ent)
                        break
                    end
                end
            else
                DeleteVehicle(ent.veh)
            end
        end

        spawnedEntities[uid] = nil
        TriggerServerEvent('leo_ai_units:clientDespawn', { unit_id = uid })
    end
end, false)

print('[leo_ai_units] Client loaded with pooling + heartbeat + handoff support')
