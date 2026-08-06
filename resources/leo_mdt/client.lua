-- MDT client: host status responses & host detail forwarding
RegisterNetEvent('leo_ai_units:hostsStatus')
AddEventHandler('leo_ai_units:hostsStatus', function(hosts)
    SendNUIMessage({ type = 'hostsStatus', hosts = hosts })
end)

RegisterNetEvent('leo_ai_units:hostDetail')
AddEventHandler('leo_ai_units:hostDetail', function(detail)
    SendNUIMessage({ type = 'hostDetail', detail = detail })
end)

RegisterNetEvent('leo_ai_units:hostsStatusUpdated')
AddEventHandler('leo_ai_units:hostsStatusUpdated', function(update)
    -- refresh hosts on update
    SendNUIMessage({ type = 'hostsStatusUpdate', update = update })
end)

-- NUI callback: request hosts status
RegisterNUICallback('requestHosts', function(data, cb)
    TriggerServerEvent('leo_ai_units:requestHosts')
    cb('ok')
end)

-- NUI callback: request host detail
RegisterNUICallback('requestHostDetail', function(data, cb)
    TriggerServerEvent('leo_ai_units:requestHostDetail', data.hostId)
    cb('ok')
end)

-- NUI callback: set host maintenance
RegisterNUICallback('setHostMaintenance', function(data, cb)
    TriggerServerEvent('leo_ai_units:setHostMaintenance', data.hostId, data.enable)
    cb('ok')
end)
