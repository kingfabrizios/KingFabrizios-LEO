-- Allow MDT to request host health status (hosts list: id, lastHeartbeat, activeCount, queuedCount)
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
        if ok and ply and ply.PlayerData and ply.PlayerData.job and ply.PlayerData.job.name == 'ai_host' then
            isDedicated = true
        end

        table.insert(hosts, {
            hostId = player,
            isDedicated = isDedicated,
            lastHeartbeat = hb,
            heartbeatAge = age,
            activeCount = active,
            queuedCount = queued
        })
    end

    TriggerClientEvent('leo_ai_units:hostsStatus', src, hosts)
end)
