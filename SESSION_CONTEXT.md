# CS:GO Server Deploy - Session Context

## Current State (2026-03-10, session 4) — WORKING
**Client connection successful.** Server runs on host (not Docker), Steam auth + VAC active, NoLobbyReservation loaded.

### What works
- srcds running directly on host at `/srv/csgo-host/` via `screen -S csgo /srv/csgo-host/start.sh`
- GSLT auth: `Connection to Steam servers successful.` + `VAC secure mode is activated.`
- MetaMod 1.12 + SourceMod 1.12 loaded
- NoLobbyReservation (eldoradoel fork) — clients can connect
- App ID 4465480, GSLT for 4465480
- Disk usage: 65% (down from 88% after removing Docker volume duplicate)

### What was the problem
1. **Docker** — `SteamAPI_Init() failed; create pipe failed` blocked all GSLT auth. Switching to host install fixed this.
2. **NoLobbyReservation** — required for 2026 clients. Without it, client sends lobby reservation request and server silently drops it ("Retrying" on client side).
3. **Gamedata** — vanz666 repo had outdated signatures. eldoradoel fork has working `CBaseServer::IsExclusiveToLobbyConnections` signature.
4. **metamod.vdf path** — needed `"../csgo/addons/metamod/bin/server"` (not `"addons/metamod/bin/server"`)

### Known issues (non-blocking)
- `databases.cfg` parse error (Line 2: property outside section) — breaks clientprefs extension
- `.env` file has unquoted special chars (`&`, `!`, `*`) — RCON_PASSWORD may not source correctly
- `exec: couldn't exec gamemode_competitive_server.cfg` — missing competitive config
- `/home/oskar/.steam/sdk32/steamclient.so` missing — non-fatal warning
- BotProfile.db 'Rank' attribute errors — cosmetic
- server.cfg settings overridden by competitive gamemode config on map change

### Files on VPS
- `/srv/csgo-host/` — game files (35 GB, from Docker volume, now standalone)
- `/srv/csgo-host/start.sh` — launch script (sources /srv/csgo/.env)
- `/srv/csgo/.env` — SERVER_PASSWORD, RCON_PASSWORD, SRCDS_TOKEN
- `/srv/csgo/server.cfg` — game settings (copied into csgo-host/csgo/cfg/)
- `/srv/csgo/Dockerfile`, `docker-compose.yml`, `entrypoint.sh` — legacy Docker setup (no longer used)

### How to operate
```bash
# Start server
screen -S csgo /srv/csgo-host/start.sh

# Detach (keep running)
Ctrl+A then D

# Reattach
screen -r csgo

# Stop server (type in srcds console)
quit

# Check if running
screen -ls

# Connect from client
connect 194.163.151.122:27015; password YOURpassword
```

### Next steps (priority order)
1. Fix databases.cfg (for clientprefs and future plugins)
2. Quote values in .env (fix RCON_PASSWORD passing)
3. Add competitive config file
4. Re-enable desired plugins (weaponpaints, knife, gloves, rankme) — needs PTaH, fixed databases.cfg
5. Create gamemode_competitive_server.cfg with custom settings
6. VPS reboot (deferred from earlier)

## History of attempts
1. Docker: App ID 730 + GSLT 730 → Steam connected but MasterRequestRestart kicked clients
2. Docker: App ID 4465480 + old GSLT (730) → "Could not establish connection to Steam servers"
3. Docker: App ID 4465480 + new GSLT (4465480) + ipc:host → No Steam auth attempt (create pipe failed)
4. **Host install: App ID 4465480 + GSLT 4465480 + NoLobbyReservation (eldoradoel) → WORKS**

## Resources
- https://github.com/CsGoat/csgo-2026-server-setup-script
- https://github.com/eldoradoel/NoLobbyReservation (working fork, master branch)
- https://github.com/vanz666/NoLobbyReservation (original, master branch, outdated gamedata)
