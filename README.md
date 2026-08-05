# KingFabrizios-LEO

Prototype scaffolding for an LSPDFR-like FiveM suite (dispatch + MDT) — Lua server, QBCore-compatible.

This repo contains initial prototype resources:
- leo_dispatch: server-side Lua dispatch prototype (console command to create incidents, broadcasts to clients)
- leo_mdt: client NUI MDT prototype (React/vanilla HTML UI served as NUI)

Setup (local dev server)
1. Place the `resources` directory inside your FiveM resources folder or add it to your server.cfg.
2. Ensure QBCore is installed and running on the server.
3. Start the resources in server.cfg:
   ensure leo_dispatch
   ensure leo_mdt
4. From the server console, run the command to create a test incident:
   lua run_script print('Use RCON/console commands or implement admin commands to create incidents')

Notes
- This is a minimal prototype to get you started. Next steps: persistence (oxmysql), permission checks (QBCore job), and improved AI spawning logic.
