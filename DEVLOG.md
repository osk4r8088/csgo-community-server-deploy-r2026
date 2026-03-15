# CS:GO 2026 Server — Development Log

Complete history of decisions, bugs, fixes, and architecture insights. Reference for future development, debugging, and feature work.

---

## v1.0 — Initial Multi-Mode Server (2026-03-10 to 2026-03-13)

### Timeline

**Day 1 (2026-03-10): Docker to Host**
- Started with Docker-based srcds. Spent hours debugging Steam authentication.
- `SteamAPI_Init() failed; create pipe failed` — Docker's IPC isolation breaks Steam's client library. `ipc:host`, `privileged`, shared `/tmp` — nothing worked.
- Abandoned Docker entirely. Installed srcds directly on host at `/srv/csgo-host/`.
- App ID patching: SteamCMD installs app 730, but the 2026 client expects 4465480. Must patch `steam.inf` and `steam_appid.txt`.
- NoLobbyReservation: The original vanz666 repo has outdated gamedata signatures. The eldoradoel fork has working ones. Without this plugin, clients get infinite "Retrying..." with no error message.
- First successful client connection after patching app ID + installing NoLobbyReservation.

**Day 2 (2026-03-11): Multi-Mode Foundation**
- Created `start.sh` with mode-based plugin activation system.
- Moved all mode-specific plugins to `plugins/disabled/`. Each boot activates only what's needed.
- Created per-mode configs: `surf.cfg`, `kz.cfg`, `dm.cfg`, `arena.cfg`, `retake.cfg`.
- Discovered `+servercfgfile` (not `+exec`) is the correct way to load per-mode configs.
- Discovered `game_type 3 game_mode 0` (Custom) avoids engine-forced casual behaviors (auto-bots, warmup extension, unwanted map votes). Used for surf, kz, arena.

**Day 3 (2026-03-12): Plugins + Database**
- Installed SurfTimer v1.1.4. Required MySQL — SQLite is explicitly unsupported.
- MariaDB 10.11 installed on VPS. User creation hit bash history expansion (`!` in password triggered `!V` expansion). Fixed by removing `!` from password.
- MySQL socket vs TCP: `localhost` in databases.cfg uses Unix socket (`/tmp/mysql.sock` which doesn't exist). Changed to `127.0.0.1` to force TCP.
- `lib32z1` required for SourceMod's MySQL extension (32-bit `libz.so.1`).
- SurfTimer tables not auto-created — had to manually import `fresh_install.sql` from the release ZIP.
- GOKZ v3.6.4 + MovementAPI v2.4.3 installed. KZ works flawlessly out of the box.
- `gokz-momsurffix` exists but causes `CheckParameters` error spam — not activated.
- Added `gokz-saveloc` (checkpoints!), `gokz-goto`, `gokz-spec`, `gokz-pistol`, `gokz-chat`.

**Day 4 (2026-03-13): Skins, Modeswitch, Polish**
- PTaH v1.1.4 installed. Extension named `PTaH.ext.2.csgo.so` (SourceMod auto-detects the `.2.csgo` suffix).
- kgns/weapons provides both `!ws` AND `!knife` in a single plugin. No separate `knife.smx` exists.
- Skin plugins need `"storage-local"` database entry in databases.cfg (uses SQLite).
- Plugin filename casing matters on Linux: `SurfTimer.smx` (not `surftimer.smx`), `movementapi.smx` (not `MovementAPI.smx`).
- Modeswitch plugin rewritten from v1 (hot-swap) to v3 (restart-based + rotation + vote):
  - v1 tried to `sm plugins load/unload` at runtime → cvars persist, game_type can't change, broken.
  - v2 used file-based IPC + `ServerCommand("quit")` → wrapper auto-restarts with new mode.
  - v3 added auto-rotation (maps-played counter per mode) + democratic vote + periodic tips.
- `!mode` renamed to `!modes` to avoid conflict with GOKZ's `!mode` (which switches KZ movement modes).
- `!modes` changed from `RegConsoleCmd` to `RegAdminCmd` — prevents any player from triggering server restarts.
- DM game_type experiment: Changed to `game_type 3` for config control, but this broke DM spawn behavior (spawns in normal CT/T spawns instead of DM spawns). Reverted to `game_type 1 game_mode 2`.
- Retake game_type experiment: Tried `game_type 3`, but the retake plugin needs competitive round structure. Reverted to `game_type 0 game_mode 1`. Retake is still partially broken (warmup doesn't exit with bots).
- SourceMod file write issue: `OpenFile("/srv/csgo/.pendingmode", "w")` fails — SM sandboxes file access. Even absolute paths under the game dir fail. Solution: `BuildPath(Path_SM, path, sizeof(path), "data/pendingmode.txt")` — writes to SM's own data directory.

---

## v1.1 — Chat Voting, Ramp Fix, Map Expansion (2026-03-15)

### Changes

**Modeswitch v4.1 — Chat-based voting**
- Complete rewrite of voting system. Regular players no longer get menus (accidental key presses during gameplay).
- `!switchmode` — RTV-style: 60% of players must request it, then mode options are listed in chat. Players vote by typing `1`, `2`, `3`, etc.
- `!modes` — Admin only: menu-based direct switch or `!modes <name>` for instant switch.
- Removed `!currentmode` and `!modemenu` commands.
- Vote numbers are suppressed from chat (clean output).
- All vote state resets on map change (fixes stuck vote bug from v3).
- Disconnecting players properly decrement the switchmode request count.
- Auto-rotation after map limit uses the same chat vote system.

**MomSurfFix v2 (GAMMACASE fork)**
- Fixes engine's `ClipVelocity` bug that causes speed loss on ramps.
- Activated for both surf and kz modes via start.sh.
- `gokz-momsurffix` (standalone) was NOT used — it caused `CheckParameters` error spam.

**Retake fix**
- `mp_maxrounds 999` (was `0`) — prevents engine from ending the match immediately.
- `mp_match_can_clinch 0` — prevents early match end.
- `mp_do_warmup_period 0` — skip warmup entirely, retakes plugin handles player readiness.
- Downloaded pre-made spawn configs from splewis/csgo-retakes for all 5 retake maps.
- Kept `game_type 0 game_mode 1` (competitive) — Custom mode breaks the retakes plugin's round restart logic.

**Map expansion**
- KZ: added kz_layercake, kz_dale, kz_dejavu, kz_rise, kz_variety_fix (removed phantom maps that were never downloaded).
- Surf: added surf_deteriorate, surf_nuclear, surf_boreas, surf_whiteout (removed phantom maps).
- de_cache added to competitive and DM map pools.
- All mapcycle files and modeswitch_maps.cfg cleaned to match actual VPS maps.

**Arena fix**
- Removed `bot_quota 1` from arena.cfg (was stealing a player slot).
- Set `bot_quota 0`, `mp_do_warmup_period 0`.

**Tips system**
- Added mode-specific tips: `!start !end !nc` for surf/kz, `!guns` for retake.
- Updated universal tips to reference `!switchmode` instead of `!modes`.

---

## Architecture Decisions

### Why restart-based mode switching (not hot-swap)

We tried hot-swapping plugins at runtime (`sm plugins load/unload`). Problems:
1. **CVars persist** — Surf's `sv_airaccelerate 150` stays after switching to competitive.
2. **game_type can't change at runtime** — Set at launch, enforced by engine.
3. **Plugin state corruption** — SurfTimer's timers, GOKZ's movement hooks, etc. don't clean up properly.

The restart-based approach is clean: write a file, quit server, wrapper picks up the file and restarts with the correct mode. Takes ~5 seconds.

### Why `game_type 3 game_mode 0` for surf/kz/arena

Valve's game modes (Casual, Competitive, DM) have hardcoded behaviors:
- Casual: auto-adds bots, forces warmup, enables vote-on-match-end.
- Competitive: enforces economy, halftime, overtime logic.
- DM: forces DM spawns (actually useful for DM, broken for everything else).

`game_type 3 game_mode 0` (Custom) gives clean control — no engine-forced behaviors, all cvars configurable.

**Exception:** DM must use `game_type 1 game_mode 2` because the engine only places DM spawns in that mode.

### Why `+servercfgfile` not `+exec`

`+exec` runs a config once at boot. But Valve's `gamemode_*.cfg` runs on every map change and overrides your settings. `+servercfgfile` replaces the server config entirely for that session, so your mode config persists across map changes.

For competitive, we don't use `+servercfgfile` — instead, `gamemode_competitive_server.cfg` runs automatically on every map change (engine loads it by naming convention).

### Why wrapper + start.sh (not just systemd restart)

systemd's `Restart=on-failure` restarts with the same arguments. But mode switching needs different arguments (`start.sh surf` vs `start.sh dm`). The wrapper script:
1. Reads `pendingmode.txt` to know what mode was requested
2. Writes `currentmode.txt` so the modeswitch plugin knows the active mode
3. Calls `start.sh` with the correct mode
4. Auto-restarts on exit (3-second delay)

systemd manages the wrapper, which manages start.sh, which manages srcds.

---

## Bug Reference

### Fixed Bugs

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| `SteamAPI_Init() failed; create pipe failed` | Docker IPC isolation | Run on host, not Docker |
| Client infinite "Retrying..." | No lobby reservation bypass | Install NoLobbyReservation (eldoradoel fork) |
| `databases.cfg` parse error | Docker entrypoint sed corruption | Deploy clean file from repo |
| RCON_PASSWORD empty after sourcing .env | Unquoted `!` triggers bash history expansion | Wrap values in single quotes |
| `[SurfTimer] Sorry SQLite is not supported` | SurfTimer requires MySQL | Install MariaDB, configure MySQL in databases.cfg |
| `dbi.mysql.ext: libz.so.1: cannot open` | Missing 32-bit zlib | `apt install lib32z1` |
| `Can't connect through socket '/tmp/mysql.sock'` | `localhost` → Unix socket, socket path wrong | Use `127.0.0.1` (forces TCP) |
| SurfTimer tables missing | Schema not auto-created | Import `fresh_install.sql` manually |
| `weaponpaints.smx: storage-local not found` | Missing database entry | Add `"storage-local"` SQLite entry to databases.cfg |
| DM spawns in CT/T positions | Used `game_type 3` (Custom) | Revert to `game_type 1 game_mode 2` |
| Surf/KZ cvars persist after mode switch | Hot-swap doesn't clear cvars | Restart-based approach (quit + restart) |
| `Could not write /srv/csgo/.pendingmode` | SourceMod sandboxes file access | Use `BuildPath(Path_SM, ...)` for SM data dir |
| `!mode` conflicts with GOKZ | Both register `sm_mode` | Renamed to `sm_modes` / `!modes` |
| Anyone can spam `!modes` (triggers restart) | Used `RegConsoleCmd` | Changed to `RegAdminCmd` |
| Retry message shows 1s before quit | Message printed at quit time | Print at start of 5-second countdown |
| Engine loads wrong metamod binary | `linux64/server.so` exists alongside correct one | Delete `linux64/server.so` |
| Vote stuck after map change | `g_bRotationVoteActive` never reset | Added state reset in `OnMapStart` |
| Surf/KZ ramp speed loss | Engine `ClipVelocity` bug | MomSurfFix v2 (GAMMACASE fork) |
| Retake match ends immediately | `mp_maxrounds 0` with competitive game type | Set `mp_maxrounds 999`, `mp_match_can_clinch 0` |
| Arena bot steals player slot | `bot_quota 1` with `bot_quota_mode "fill"` | Set `bot_quota 0` |
| Menu vote during gameplay | Players accidentally press 1-3 while playing | Chat-based voting in modeswitch v4.1 |

### Known / Unfixed Issues

| Issue | Notes |
|-------|-------|
| Retake needs 2-player testing | Spawn configs downloaded, 1-player instant-wins (expected) |
| Arena needs 2-player testing | bot_quota fixed, team joining untested with 2 players |
| Surf zones need manual setup | Admin must `!zones` on each new map |
| FastDL is ephemeral | Running `python3 -m http.server 27020` — needs systemd service |
| `/home/oskar/.steam/sdk32/steamclient.so` missing | Non-fatal warning, doesn't affect functionality |
| BotProfile.db 'Rank' attribute errors | Cosmetic SM log spam, doesn't affect gameplay |

---

## Plugin Inventory

### Permanent (always loaded)

| Plugin | Purpose | Notes |
|--------|---------|-------|
| NoLobbyReservation | Client connections | REQUIRED — without it, nobody can connect |
| modeswitch | Mode switching + rotation | Custom plugin, always loaded |

### Per-Mode (in `plugins/disabled/`, activated by `start.sh`)

| Plugin | Modes | Notes |
|--------|-------|-------|
| weaponpaints | All | !ws and !knife (one plugin, not two) |
| gloves | All | !gloves |
| kento_rankme | Competitive, Retake | Player stats + ranking |
| rockthevote | All | RTV map voting |
| mapchooser | All | Map vote on match end |
| nominations | All | Nominate maps for vote |
| retakes | Retake | Site retakes |
| retakes_standardallocator | Retake | Random weapon loadouts |
| momsurffix2 | Surf, KZ | Ramp speed fix (GAMMACASE fork) |
| SurfTimer | Surf | Timer + leaderboards (MySQL) |
| SurfTimer-telefinder | Surf | Auto-find teleport destinations |
| EndTouchFix | Surf | Fix zone end-touch detection |
| st-mapchooser | Surf | SurfTimer's own map vote |
| st-rockthevote | Surf | SurfTimer's own RTV |
| st-nominations | Surf | SurfTimer's own nominations |
| st-voteextend | Surf | Vote to extend map time |
| multi1v1 | Arena | 1v1 arena system |
| movementapi | KZ | Movement detection (GOKZ dependency) |
| gokz-core | KZ | Core KZ functionality |
| gokz-hud | KZ | Timer HUD |
| gokz-jumpstats | KZ | Jump statistics |
| gokz-localdb | KZ | Local database storage |
| gokz-localranks | KZ | Local player rankings |
| gokz-mode-vanilla | KZ | Vanilla movement mode |
| gokz-mode-simplekz | KZ | SimpleKZ movement mode |
| gokz-mode-kztimer | KZ | KZTimer movement mode |
| gokz-replays | KZ | Run replay recording |
| gokz-anticheat | KZ | Anti-cheat checks |
| gokz-quiet | KZ | Reduce chat noise |
| gokz-tips | KZ | Periodic tips |
| gokz-saveloc | KZ | Checkpoints (save/load position) |
| gokz-goto | KZ | Teleport to players |
| gokz-spec | KZ | Spectator tools |
| gokz-pistol | KZ | Pistol selection |
| gokz-chat | KZ | Chat formatting |

---

## Server Infrastructure

### VPS
- **Provider:** Contabo
- **OS:** Ubuntu 24.04
- **RAM:** 8 GB
- **IP:** 194.163.151.122
- **Disk:** 65% used (server files ~35 GB)

### Paths
```
/srv/csgo-host/              # Game files + scripts
/srv/csgo-host/csgo/         # Game data (maps, configs, addons)
/srv/csgo/.env               # Credentials (not in game dir)
```

### Databases
- **MariaDB 10.11** on localhost
- `surftimer` — SurfTimer data (user: `surftimer@127.0.0.1`)
- GOKZ uses SQLite by default (can switch to MySQL)

### Network
- **27015/udp** — Game traffic
- **27015/tcp** — RCON
- **27020/tcp** — FastDL (when running)

### Other services on this VPS
- Caddy (reverse proxy)
- Authentik (SSO at auth.ospw.de)
- Element/Synapse/Coturn (Matrix chat at chat.ospw.de)
- Django dashboard (app.ospw.de)

---

## Roadmap / TODO

### High Priority
- [ ] FastDL systemd service (replace ephemeral python HTTP)
- [ ] srcds systemd service battle-testing (csgo.service + wrapper)
- [ ] Test retake with 2+ players (spawn configs in place)
- [ ] Test arena 1v1 with 2 players (bot_quota fixed)
- [ ] Set up surf zones on more maps

### Medium Priority
- [ ] csgo.ospw.de — web dashboard (live status, connect link, stats)
- [ ] FastDL bzip2 compression for custom maps
- [ ] Monitor server RAM/CPU usage over time
- [ ] Add more maps as found

### Low Priority
- [ ] Multi-1v1 flashbang/knife round sub-plugins
- [ ] RankMe web dashboard integration (app.ospw.de)
- [ ] Server log parsing for stats (app.ospw.de)
- [ ] Automated backup of SM data + MySQL
- [ ] Consider retakes_sitepicker for retake map selection

### Ideas
- Custom MOTD with mode info and server rules
- Discord webhook for mode changes / player count
- Map download automation from GameBanana API
- Per-player weapon skin persistence across mode switches
