-- MDT client: host status responses
RegisterNetEvent('leo_ai_units:hostsStatus')
AddEventHandler('leo_ai_units:hostsStatus', function(hosts)
    SendNUIMessage({ type = 'hostsStatus', hosts = hosts })
end)

-- NUI callback: request hosts status
RegisterNUICallback('requestHosts', function(data, cb)
    TriggerServerEvent('leo_ai_units:requestHosts')
    cb('ok')
end)
