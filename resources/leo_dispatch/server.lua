-- leo_dispatch/server.lua
-- Minimal dispatch prototype. Server-authoritative incident creation and broadcast to clients.

local incidentCounter = 0

-- Utility: create a simple incident and broadcast
local function createIncident(itype, coords, detail)
    incidentCounter = incidentCounter + 1
    local incident = {
        id = incidentCounter,
        type = itype or "unknown",
        coords = coords or { x = 0.0, y = 0.0, z = 0.0 },
        detail = detail or "",
        status = "pending",
        createdAt = os.time()
    }

    print(('[leo_dispatch] Created incident #%s type=%s'):format(incident.id, incident.type))

    -- Broadcast to all clients (MDT / HUDs)
    TriggerClientEvent('leo_dispatch:incidentCreated', -1, incident)

    -- TODO: persist to DB (oxmysql), assign AI units, etc.
    return incident
end

-- Console command for server operators to create a test incident
RegisterCommand('leo_incident', function(source, args, raw)
    if source ~= 0 then
        print('[leo_dispatch] This command may only be run from the server console')
        return
    end

    local itype = args[1] or 'traffic_collision'
    -- simple coords parsing: x y z
    local coords = { x = tonumber(args[2]) or 0.0, y = tonumber(args[3]) or 0.0, z = tonumber(args[4]) or 0.0 }
    local detail = table.concat(args, ' ', 5) or ''

    createIncident(itype, coords, detail)
end, false)

-- Remote RPC: allow authorized code to create incidents (server-to-server or admin scripts)
RegisterNetEvent('leo_dispatch:createIncident')
AddEventHandler('leo_dispatch:createIncident', function(data)
    -- Data should be validated server-side. Here we accept a minimal shape.
    createIncident(data.type, data.coords, data.detail)
end)
