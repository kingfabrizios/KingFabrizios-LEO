leo_ai_units

Simple AI unit management skeleton for KingFabrizios-LEO.

Features:
- Server requests a client host to spawn AI peds/vehicles for incidents.
- Client spawns entities and reports back net ids and periodic status updates.
- Debug commands: `leo_assign <incident_id> [x] [y] [z]` on the server console to assign a test unit; `leo_despawn` on client to clear spawned units.

Notes & next steps:
- Host selection is currently naive (first connected player). Replace with nearest-player selection or a dedicated host role.
- Add pooling and limits to avoid client/server overload.
- Add persistence (incidents_units table) when stable.

Testing:
1. Ensure feature branch is checked out and resources are placed in your FiveM resources directory.
2. Add to server.cfg: ensure leo_ai_units (after qb-core and oxmysql if used).
3. Start server and spawn an incident. From server console run:
   leo_assign <incident_id> <x> <y> <z>
4. Check client logs for spawnRequest handling and confirm the MDT updates with unitUpdate events.
