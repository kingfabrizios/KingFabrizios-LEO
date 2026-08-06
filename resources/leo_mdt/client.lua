-- MDT client: host status responses & alert forwarding

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
    SendNUIMessage({ type = 'hostsStatusUpdate', update = update })
end)

-- forward alerts to NUI
RegisterNetEvent('leo_ai_units:hostAlert')
AddEventHandler('leo_ai_units:hostAlert', function(alert)
    SendNUIMessage({ type = 'hostAlert', alert = alert })
end)

RegisterNetEvent('leo_ai_units:permissionDenied')
AddEventHandler('leo_ai_units:permissionDenied', function(info)
    SendNUIMessage({ type = 'permissionDenied', info = info })
end)

-- NUI callbacks
RegisterNUICallback('requestHosts', function(data, cb)
    TriggerServerEvent('leo_ai_units:requestHosts')
    cb('ok')
end)

RegisterNUICallback('requestHostDetail', function(data, cb)
    TriggerServerEvent('leo_ai_units:requestHostDetail', data.hostId)
    cb('ok')
end)

RegisterNUICallback('setHostMaintenance', function(data, cb)
    TriggerServerEvent('leo_ai_units:setHostMaintenance', data.hostId, data.enable)
    cb('ok')
end)

RegisterNUICallback('assignUnit', function(data, cb)
    TriggerServerEvent('leo_ai_units:assign', { incident_id = data.incident_id }, data.template)
    cb('ok')
end)
