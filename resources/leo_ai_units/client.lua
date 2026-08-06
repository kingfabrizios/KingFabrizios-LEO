-- client additions: NUI handlers and forwards already exist; add accept response when spawnRequest arrives

-- In spawnRequest handler after successful network spawn, client continues to call existing server event 'leo_ai_units:clientSpawned'. That server-side now uses clientSpawned as the ACK for handoff.
-- No additional client changes necessary beyond existing spawn pipeline (clientSpawned) which acts as accept/ack.

print('[leo_ai_units] Client NUI handlers updated for MDT controls (no code changes required here)')
