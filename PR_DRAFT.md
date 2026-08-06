---
This PR draft describes the feature work on branch `feature/leo-dispatch-mdt-lua-qb`.

Summary
- MDT React UI prototype (incidents, units panel) and host health dashboard.
- AI unit manager (leo_ai_units) improvements:
  - Persistent queued assignments (DB-backed incidents_units table)
  - Host failover and reassignment
  - Host heartbeats and graceful handoff (prepareHandoff / handoffReady / completeHandoff)
  - Hardened handoff with accept/ack flow and pending handoff timeouts
  - Server-side host maintenance and whitelist controls
  - MDT controls to view host details and set maintenance
  - MDT map view for host locations and alerts/filters for host health

Files changed (high level)
- resources/leo_mdt/html/index.html (added Leaflet map assets for prototype)
- resources/leo_mdt/html/script.js (React UI: hosts panel, map, filters, host detail modal)
- resources/leo_mdt/html/style.css (styles for map, modal, alerts)
- resources/leo_mdt/client.lua (NUI callbacks, host status forwarding)
- resources/leo_ai_units/server.lua (heartbeat, persistent queue, host failover, pending handoffs, permission checks)
- resources/leo_ai_units/client.lua (heartbeat sender and handoff handlers)

Testing steps
1. Checkout branch `feature/leo-dispatch-mdt-lua-qb` and install resources to your FiveM resources folder.
2. Ensure server.cfg loads in this order: qb-core, oxmysql, leo_dispatch, leo_mdt, leo_ai_units.
3. Start server and have multiple clients join. Assign one client the `ai_host` job if you want a dedicated host.
4. Open MDT (/mdt) as an authorized dispatcher job. Select an incident and press Refresh Hosts to populate host list.
5. Confirm host positions and counts appear in the map and hosts panel.
6. Assign several units to an incident so some are queued.
7. On a host, trigger a prepareHandoff (simulate flaky network by pausing heartbeats) — server requests handoff and you should see the graceful handoff flow: new host receives spawnRequest and when it reports spawned, the old host receives completeHandoff and cleans up local entities.
8. Toggle maintenance on a host from the MDT and verify it is no longer selected as a host for new assignments.
9. Restart server to verify queued assignments persist and are restored.

Notes
- MDT map uses Leaflet in a simple prototype mode; coordinates are plotted as simple x/y points (not projected to real-world lat/lon). For production improve mapping or integrate a proper geocoder.
- Server-side maintenance/whitelist endpoints are permission-protected by job check (default dispatcherJobs list). Adjust allowed jobs as needed.
- Pending handoff timeout defaults to 15s; tune HEARTBEAT and handoff timeouts in server.lua as needed.

Requested reviewers
- Review server-side concurrency around pendingHandoffs and DB updates.
- Review UI accessibility of the MDT host dashboard and map.

---
