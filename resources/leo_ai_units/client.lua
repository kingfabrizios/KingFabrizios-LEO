-- resources/leo_ai_units/client.lua
-- Client-side AI host: listens for spawn requests and creates peds/vehicles locally.

local QBCore = exports['qb-core']:GetCoreObject()
local spawnedEntities = {}

-- Helper: safe model loading
local function LoadModel(model)
    local mHash = type(model) == 'string' and GetHashKey(model) or model
    if not IsModelInCdimage(mHash) or not IsModelAMissionEntity(mHash) then
        -- proceed anyway; common ped/vehicle names will work if present on client
    end

    RequestModel(mHash)
    local timeout = 50
    while not HasModelLoaded(mHash) and timeout > 0 do
        Citizen.Wait(50)
        timeout = timeout - 1
    end
    return mHash
end

RegisterNetEvent('leo_ai_units:spawnRequest')
AddEventHandler('leo_ai_units:spawnRequest', function(unit)
    -- Only certain clients should accept spawn requests in production; this prototype accepts all
    if not unit or not unit.unit_id then return end

    print(('[leo_ai_units][client] spawnRequest received for unit %d'):format(unit.unit_id))

    local pedHash = unit.pedModel and LoadModel(unit.pedModel) or nil
    local vehHash = unit.vehicleModel and LoadModel(unit.vehicleModel) or nil

    local x,y,z = unit.coords.x or unit.coords[1] or 0.0, unit.coords.y or unit.coords[2] or 0.0, unit.coords.z or unit.coords[3] or 0.0

    local createdPed = nil
    local createdVeh = nil

    if vehHash then
        createdVeh = CreateVehicle(vehHash, x, y, z + 0.5, 0.0, true, false)
        SetVehicleOnGroundProperly(createdVeh)
        SetEntityAsMissionEntity(createdVeh, true, true)
    end

    if pedHash then
        createdPed = CreatePed(4, pedHash, x, y, z + 0.5, 0.0, true, false)
        SetPedAsCop(createdPed, true)
        SetEntityAsMissionEntity(createdPed, true, true)
        if createdVeh then
            TaskWarpPedIntoVehicle(createdPed, createdVeh, -1)
        else
            -- simple behavior: walk to the target coords if specified
            TaskGoStraightToCoord(createdPed, x, y, z, 1.0, -1, 0.0, 0.0)
        end
    end

    -- Network ownership: ensure entity is networked so server & others can see it
    local netId = nil
    if createdPed and DoesEntityExist(createdPed) then
        netId = NetworkGetNetworkIdFromEntity(createdPed)
        SetNetworkIdCanMigrate(netId, true)
    elseif createdVeh and DoesEntityExist(createdVeh) then
        netId = NetworkGetNetworkIdFromEntity(createdVeh)
        SetNetworkIdCanMigrate(netId, true)
    end

    if netId then
        spawnedEntities[unit.unit_id] = { ped = createdPed, veh = createdVeh, netId = netId }
        -- report back to server that the unit is spawned
        TriggerServerEvent('leo_ai_units:clientSpawned', { unit_id = unit.unit_id, netId = netId, entityType = (createdPed and 'ped' or 'vehicle') })

        -- start periodic status pings
        Citizen.CreateThread(function()
            while spawnedEntities[unit.unit_id] do
                local ent = spawnedEntities[unit.unit_id]
                local entId = ent.ped and ent.ped or ent.veh
                if entId and DoesEntityExist(entId) then
                    local px,py,pz = table.unpack(GetEntityCoords(entId, true))
                    TriggerServerEvent('leo_ai_units:clientStatus', { unit_id = unit.unit_id, status = 'enroute', position = { x = px, y = py, z = pz } })
                else
                    -- entity missing: report despawn and cleanup
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

-- Simple cleanup command for clients to despawn an assigned unit locally
RegisterCommand('leo_despawn', function()
    -- debug CLI: despawn all spawnedEntities on this client
    for uid, ent in pairs(spawnedEntities) do
        if ent.ped and DoesEntityExist(ent.ped) then
            DeletePed(ent.ped)
        end
        if ent.veh and DoesEntityExist(ent.veh) then
            DeleteVehicle(ent.veh)
        end
        spawnedEntities[uid] = nil
        TriggerServerEvent('leo_ai_units:clientDespawn', { unit_id = uid })
    end
end, false)

print('[leo_ai_units] Client loaded')
