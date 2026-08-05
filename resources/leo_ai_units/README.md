leo_ai_units

Added DB persistence for AI units. New file: resources/leo_ai_units/db/schema.sql

Behavior:
- On spawn (clientSpawned), server inserts a record into incidents_units and stores the inserted id on the in-memory unit as db_id.
- On despawn (clientDespawn), if db_id exists the server updates the DB record with status and despawned_at.
- MDT/clients can request recent units for an incident via 'leo_ai_units:requestUnits' -> server returns 'leo_ai_units:recentUnits' with results.

Testing:
1. Ensure oxmysql is configured and available on the server.
2. Start the server; resource start attempts to create incidents_units table automatically.
3. Create an incident, assign units, and observe DB rows in incidents_units table.
4. Request units from a client by triggering 'leo_ai_units:requestUnits' with the incident id (MDT will use this later).
