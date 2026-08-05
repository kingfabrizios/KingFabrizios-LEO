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
        incident_id = incidentCounter, -- temporary id; will be replaced by DB id when available
        type = itype or "unknown",
        coords = coords or { x = 0.0, y = 0.0, z = 0.0 },
        detail = detail or "",
        status = "pending",
        created_at = os.time()
    }

    print(('[leo_dispatch] Creating incident (temp #%s) type=%s'):format(incident.incident_id, incident.type))

    -- If DB is available, insert first and use DB id as the authoritative incident id
    if exports['oxmysql'] then
        local insertSql = "INSERT INTO incidents (incident_id, type, detail, x, y, z, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, NOW())"
        local params = { 0, incident.type, incident.detail, incident.coords.x, incident.coords.y, incident.coords.z, incident.status }

        -- Prefer oxmysql.insert if available (returns insert id in callback)
        if exports['oxmysql'].insert then
            exports.oxmysql:insert(insertSql, params, function(insertId)
                if insertId and tonumber(insertId) then
                    incident.db_id = tonumber(insertId)
                    incident.incident_id = incident.db_id
                    -- update incident_id field so future selects return a meaningful id
                    local updateSql = "UPDATE incidents SET incident_id = ? WHERE id = ?"
                    exports.oxmysql:execute(updateSql, { incident.incident_id, incident.db_id })
                    print(('[leo_dispatch] Persisted incident (db id=%s)'):format(incident.db_id))
                else
                    -- fallback: keep runtime id
                    print('[leo_dispatch] oxmysql.insert returned no insert id; using runtime incident id')
                end

                -- store and broadcast
                storeIncidentInMemory(incident)
                TriggerClientEvent('leo_dispatch:incidentCreated', -1, incident)
            end)
        else
            -- Fallback to execute and attempt to parse result
            exports.oxmysql:execute(insertSql, params, function(result)
                local insertId = nil
                if type(result) == 'number' then
                    insertId = result
                elseif result and result.insertId then
                    insertId = result.insertId
                end

                if insertId then
                    incident.db_id = insertId
                    incident.incident_id = incident.db_id
                    local updateSql = "UPDATE incidents SET incident_id = ? WHERE id = ?"
                    exports.oxmysql:execute(updateSql, { incident.incident_id, incident.db_id })
                    print(('[leo_dispatch] Persisted incident (db id=%s)'):format(incident.db_id))
                else
                    print('[leo_dispatch] Failed to determine DB insert id; using runtime incident id')
                end

                storeIncidentInMemory(incident)
                TriggerClientEvent('leo_dispatch:incidentCreated', -1, incident)
            end)
        end

        return incident
    end

    -- No DB: store in memory and broadcast using runtime id
    print(('[leo_dispatch] Created incident #%s type=%s (in-memory only)'):format(incident.incident_id, incident.type))
    storeIncidentInMemory(incident)
    TriggerClientEvent('leo_dispatch:incidentCreated', -1, incident)
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
        local sql = "SELECT id AS db_id, IF(incident_id=0, id, incident_id) AS incident_id, type, detail, x, y, z, status, created_at FROM incidents ORDER BY created_at DESC LIMIT 50"
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
