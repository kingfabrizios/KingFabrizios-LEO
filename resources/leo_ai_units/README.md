leo_ai_units

Simple AI unit management skeleton for KingFabrizios-LEO.

This iteration adds spawn limits per host and per incident, queuing on busy hosts, and client-side pooling to reuse ped/vehicle entities.

Highlights:
- Server:
  - MAX_UNITS_PER_HOST (default 4) — if a host is at capacity new assignments are queued for that host
  - MAX_UNITS_PER_INCIDENT (default 6) — prevents runaway assignments for a single incident
  - pendingQueue per host — queued units are dispatched automatically when the host frees capacity
- Client:
  - Pooling for ped/vehicle models (MAX_POOL_PER_MODEL = 3 by default)
  - Reuses pooled entities when possible to reduce create/delete churn and improve performance
  - `leo_despawn` command now frees pooled entities instead of outright deleting them

Testing:
1. Ensure feature branch is checked out and resources are placed in your FiveM resources directory.
2. Add to server.cfg: ensure leo_ai_units (after qb-core and oxmysql if used).
3. Start server and spawn an incident. From server console run several leo_assign commands to hit the host limit:
   - leo_assign <incident_id> <x> <y> <z>
   - Repeat to exceed MAX_UNITS_PER_HOST and observe queued behavior.
4. On the host client, use /mdt or watch client logs to see spawnRequest handlers. Use the `leo_despawn` command on the host to free pooled entities and observe the server dispatching queued units.

Notes & next steps:
- You can tune MAX_UNITS_PER_HOST and MAX_UNITS_PER_INCIDENT in resources/leo_ai_units/server.lua.
- Pooling is model-specific and bounded by MAX_POOL_PER_MODEL on the client; unpooled transient entities are still created if the pool is exhausted.
- Consider adding persistence for queued assignments and unit records (incidents_units table) for long-running servers.
