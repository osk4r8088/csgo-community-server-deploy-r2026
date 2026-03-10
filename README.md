# csgo-server-ospw2026
Modular CSGO Server for 2026 Release


## CS:GO 2026 Server — Status Report

### What went wrong (and why)

**Docker was the root cause.** CS:GO's srcds process needs direct access to Steam's IPC (inter-process communication) layer. Inside a Docker container, this fails with `SteamAPI_Init() failed; create pipe failed`, which silently blocks ALL Steam authentication. No GSLT login, no VAC, no internet mode — the server runs but thinks it's LAN-only.

We tried 3 Docker approaches (different app IDs, GSLT tokens, `ipc: host` flag) before confirming that every working CS:GO 2026 community server runs srcds **directly on the host**. This matches the CsGoat reference setup.

**Secondary issues solved:**
- **NoLobbyReservation plugin** — REQUIRED. The 2026 client uses a lobby reservation system. Without this plugin, the server silently drops connection attempts (client shows "Retrying..." forever).
- **Gamedata mismatch** — The original vanz666 repo had outdated memory signatures. The eldoradoel fork has working ones for the current server binary.
- **metamod.vdf path** — Needed `"../csgo/addons/metamod/bin/server"` instead of the relative path the MetaMod package ships with.

### Current working setup

| Component | Status |
|---|---|
| Host install at `/srv/csgo-host/` | Working |
| Steam auth (GSLT for app 4465480) | Working |
| VAC secure mode | Active |
| MetaMod 1.12 + SourceMod 1.12 | Loaded |
| NoLobbyReservation (eldoradoel) | Loaded |
| Client connect | Working |
| Disk usage | 65% (was 88%) |

**Not Docker.** Server runs via `screen -S csgo /srv/csgo-host/start.sh`. Config/passwords in `/srv/csgo/.env`.

### What's broken / incomplete

1. **databases.cfg** — Parse error (line 2, property outside section). The Docker entrypoint's `sed` command corrupted it. Breaks `clientprefs` extension and any plugin needing SQLite (rankme, weaponpaints).

2. **`.env` quoting** — `RCON_PASSWORD=W4d96&2?!V*N` has unquoted `&` which bash interprets as a background operator. RCON likely doesn't work. Needs quotes around values.

3. **Disabled plugins** — weaponpaints, gloves, knife, rankme are in `plugins/disabled/`. They need PTaH extension + fixed databases.cfg to work.

4. **No auto-restart** — If the VPS reboots, the server doesn't come back. Needs a systemd service or cron @reboot.

5. **server.cfg overridden** — Competitive gamemode loads its own settings on map change, overriding your cfg. Need a `gamemode_competitive_server.cfg`.

6. **No SteamCMD on host** — Game updates require reinstalling SteamCMD outside Docker.

### Recommendations for full playability

**Priority 1 — Fix now (quick wins):**
- Fix `databases.cfg` — just need to rewrite the file properly
- Quote `.env` values — wrap passwords in single quotes
- Create `gamemode_competitive_server.cfg` with your 128-tick settings

**Priority 2 — Plugins:**
- Re-enable weaponpaints, knife, gloves, rankme after databases.cfg is fixed
- PTaH extension needs the correct version for SourceMod 1.12

**Priority 3 — Operations:**
- Add systemd service for auto-start on reboot
- Install SteamCMD on host for future game updates
- VPS reboot (still pending from apt upgrade)

**Priority 4 — Nice to have:**
- GOTV for spectating/demos
- Custom map rotation
- Admin setup (SourceMod admins.cfg with your Steam ID)
- Rate limiting / connection logging
- Integration with app.ospw.de dashboard (player count, match stats via log parsing)

### Files to sync next session

Before continuing, cat these from VPS so local copies stay in sync:
```
/srv/csgo-host/start.sh
/srv/csgo-host/csgo/addons/metamod.vdf
/srv/csgo-host/csgo/addons/sourcemod/gamedata/nolobbyreservation.games.txt
/srv/csgo-host/csgo/addons/sourcemod/configs/databases.cfg
```

Everything is documented in `csgo-server/SESSION_CONTEXT.md` and memory. Next chat can pick up right where we left off.
