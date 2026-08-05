-- leo_mdt/server.lua
-- Server-side permission checks for MDT access using QBCore

local QBCore = exports['qb-core']:GetCoreObject()

RegisterNetEvent('leo_mdt:requestOpen')
AddEventHandler('leo_mdt:requestOpen', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local allowed = false

    if Player and Player.PlayerData and Player.PlayerData.job then
        local jobName = Player.PlayerData.job.name
        -- allow police/sheriff jobs - adjust to your server's job names
        if jobName == 'police' or jobName == 'sheriff' then
            allowed = true
        end
    end

    TriggerClientEvent('leo_mdt:openAuthorized', src, allowed)
end)
