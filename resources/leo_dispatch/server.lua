-- leo_dispatch/server.lua
-- Dispatch prototype with oxmysql persistence for incidents.

local incidentCounter = 0
local incidentsStore = {}
local QBCore = exports['qb-core']:GetCoreObject()

-- Ensure DB table exists on resource start
AddEventHandler('onResourceStart', function(resourceName)
    if (GetCurrentResourceName() ~= resourceName) then return end

    local schema = [[
    CREATE TABLE IF NOT EXISTS `incidents` (
        `id` INT AUTO_INCREMENT PRIMARY KEY,
        `incident_id` INT NOT NULL,
        `type` VARCHAR(64) NOT NULL,
        `detail` TEXT,
        `x` DOUBLE,
        `y` DOUBLE,
        `z` DOUBLE,
        `status` VARCHAR(32),
        `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]

    -- execute schema creation
    if exports['oxmysql'] then
        exports.oxmysql:execute(schema, {}, function()
            print('[leo_dispatch] incidents table ready')
        end)
    else
        print('[leo_dispatch] oxmysql not available - DB persistence disabled')
    end
end)

-- Utility: add incident to in-memory store (keep recent N)
local function storeIncidentInMemory(incident)
    table.insert(incidentsStore, 1, incident)
    -- keep only last 200 incidents
    while #incidentsStore > 200 do
        table.remove(incidentsStore)
    end
end

-- Utility: create a simple incident, broadcast, and persist
local function createIncident(itype, coords, detail)
    incidentCounter = incidentCounter + 1
    local incident = {
        incident_id = incidentCounter,
        type = itype or "unknown",
        coords = coords or { x = 0.0, y = 0.0, z = 0.0 },
        detail = detail or "",
        status = "pending",
        created_at = os.time()
    }

    print(('[leo_dispatch] Created incident #%s type=%s'):format(incident.incident_id, incident.type))

    -- Broadcast to all clients (MDT / HUDs)
    TriggerClientEvent('leo_dispatch:incidentCreated', -1, incident)

    -- Persist to DB if available
    if exports['oxmysql'] then
        local sql = "INSERT INTO incidents (incident_id, type, detail, x, y, z, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, NOW())"
        exports.oxmysql:execute(sql, { incident.incident_id, incident.type, incident.detail, incident.coords.x, incident.coords.y, incident.coords.z, incident.status }, function(result)
            -- oxmysql's callback may return an insert id or affected rows depending on version
            local dbId = nil
            if type(result) == 'number' then
                dbId = result
            elseif result and result.insertId then
                dbId = result.insertId
            end
            if dbId then
                incident.db_id = dbId
                print(('[leo_dispatch] Persisted incident (db id=%s)'):format(dbId))
            else
                print('[leo_dispatch] Persisted incident (unknown db id)')
            end
        end)
    end

    -- store in memory for quick retrieval
    storeIncidentInMemory(incident)

    -- TODO: assign AI units, etc.
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
    local detail = ''
    if #args >= 5 then
        -- join args 5..n
        for i=5, #args do
            detail = detail .. ' ' .. args[i]
        end
        detail = detail:sub(2)
    end

    createIncident(itype, coords, detail)
end, false)

-- Remote RPC: allow authorized code to create incidents (server-to-server or admin scripts)
RegisterNetEvent('leo_dispatch:createIncident')
AddEventHandler('leo_dispatch:createIncident', function(data)
    -- Data should be validated server-side. Here we accept a minimal shape.
    createIncident(data.type, data.coords, data.detail)
end)

-- Provide recent incidents to clients on request
RegisterNetEvent('leo_dispatch:requestRecentIncidents')
AddEventHandler('leo_dispatch:requestRecentIncidents', function()
    local src = source
    if exports['oxmysql'] then
        local sql = "SELECT incident_id, type, detail, x, y, z, status, created_at FROM incidents ORDER BY created_at DESC LIMIT 50"
        exports.oxmysql:execute(sql, {}, function(results)
            if results then
                TriggerClientEvent('leo_dispatch:recentIncidents', src, results)
            else
                -- fallback to in-memory store
                TriggerClientEvent('leo_dispatch:recentIncidents', src, incidentsStore)
            end
        end)
    else
        -- return in-memory store
        TriggerClientEvent('leo_dispatch:recentIncidents', src, incidentsStore)
    end
end)
