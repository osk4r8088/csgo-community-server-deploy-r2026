# CS:GO 2026 Multi-Mode Dedicated Server

A complete multi-mode CS:GO dedicated server setup for Valve's 2026 standalone re-release (App ID 4465480). One server, six game modes, seamless in-game switching.

**Modes:** Competitive, Retake, Surf, FFA Deathmatch, 1v1 Arena, KZ/Climb

## Requirements

- Ubuntu 22.04+ (tested on 24.04)
- 35 GB disk space, 2+ GB RAM
- SteamCMD
- MariaDB/MySQL (for SurfTimer)
- A GSLT for app **4465480** from [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers)

## Quick Start

### 1. Install SteamCMD + download server files

```bash
sudo apt update && sudo apt install -y lib32gcc-s1 lib32stdc++6 lib32z1 screen
# Install SteamCMD per https://developer.valvesoftware.com/wiki/SteamCMD

steamcmd +force_install_dir /srv/csgo-host +login anonymous +app_update 740 validate +quit
```

### 2. Patch for 2026 standalone client

The 2026 client uses App ID 4465480, but SteamCMD downloads app 730. These patches are also applied automatically by `start.sh` on every boot.

```bash
# Remove bundled libgcc (conflicts with system lib, breaks Steam auth)
rm -f /srv/csgo-host/bin/libgcc_s.so.1

# Patch app ID from 730 to 4465480
sed -i 's/appID=730/appID=4465480/g' /srv/csgo-host/csgo/steam.inf
echo "4465480" > /srv/csgo-host/steam_appid.txt
```

### 3. Install MetaMod + SourceMod

Download **Source 1** builds (NOT Source 2/CS2):

```bash
cd /srv/csgo-host/csgo

# MetaMod 1.12
wget https://mms.alliedmods.net/mmsdrop/1.12/mmsource-1.12.0-git1219-linux.tar.gz
tar -xzf mmsource-1.12.0-git1219-linux.tar.gz

# SourceMod 1.12
wget https://sm.alliedmods.net/smdrop/1.12/sourcemod-1.12.0-git7223-linux.tar.gz
tar -xzf sourcemod-1.12.0-git7223-linux.tar.gz
```

Fix the MetaMod VDF loader — replace `addons/metamod.vdf` with:

```
"Plugin"
{
  "file" "../csgo/addons/metamod/bin/server"
}
```

**Important:** Also delete `csgo/addons/metamod/bin/linux64/server.so` if it exists — the engine prefers the `linux64/` path and will load the wrong binary.

### 4. Install NoLobbyReservation (REQUIRED)

Without this plugin, clients cannot connect at all. The 2026 client uses a lobby reservation system that must be bypassed.

```bash
cd /srv/csgo-host/csgo/addons/sourcemod

wget -O nolobby.zip "https://github.com/eldoradoel/NoLobbyReservation/archive/refs/heads/master.zip"
unzip nolobby.zip

cp NoLobbyReservation-master/csgo/addons/sourcemod/gamedata/nolobbyreservation.games.txt gamedata/
cp NoLobbyReservation-master/csgo/addons/sourcemod/scripting/nolobbyreservation.sp scripting/NoLobbyReservation.sp

cd scripting && chmod +x spcomp
./spcomp NoLobbyReservation.sp -o ../plugins/NoLobbyReservation.smx
cd .. && rm -rf nolobby.zip NoLobbyReservation-master
```

### 5. Configure credentials

```bash
mkdir -p /srv/csgo
cp .env.example /srv/csgo/.env
nano /srv/csgo/.env   # Fill in SRCDS_TOKEN, passwords, API key
```

**Important:** Values with special characters (`&`, `!`, `*`) must be wrapped in single quotes. Example: `RCON_PASSWORD='W4d96&2?V*N'`

### 6. Run automated setup

```bash
git clone https://github.com/osk4r8088/csgo-server-ospw2026.git /tmp/csgo-setup
cd /tmp/csgo-setup
sudo ./setup.sh
```

The setup script:
- Deploys all configs, scripts, and mapcycle files
- Downloads and installs all mode plugins (retakes, SurfTimer, multi-1v1, GOKZ, PTaH, skins)
- Creates MySQL databases for SurfTimer (+ optional GOKZ)
- Downloads community maps (surf, kz, arena)
- Compiles the modeswitch plugin
- Installs the systemd service
- Fixes common issues (databases.cfg corruption, .env quoting)

Skip specific steps: `--skip-db` (skip MySQL), `--skip-maps` (skip map downloads).

### 7. Start the server

```bash
# With auto-restart wrapper (recommended — enables in-game mode switching)
screen -S csgo /srv/csgo-host/csgo-wrapper.sh competitive

# Or with systemd (survives reboot)
sudo systemctl start csgo
```

### 8. Connect

```
connect YOUR_SERVER_IP:27015; password YOUR_PASSWORD
```

---

## Architecture

### How mode switching works

The server uses a **restart-based** approach for mode switching. Hot-swapping plugins at runtime doesn't work reliably — cvars from the previous mode persist, `game_type` can't change, and plugin state gets corrupted.

```
                    +-----------------+
                    | csgo-wrapper.sh |  <-- auto-restart loop
                    +--------+--------+
                             |
               reads pendingmode.txt
               writes currentmode.txt
                             |
                    +--------v--------+
                    |    start.sh     |  <-- activates per-mode plugins
                    |  (mode=surf)    |       copies mapcycle, sets game_type
                    +--------+--------+
                             |
                    +--------v--------+
                    |     srcds       |  <-- CS:GO server process
                    |  modeswitch.sp  |       handles !modes, rotation votes
                    +--------+--------+
                             |
              on mode switch: writes pendingmode.txt
              then calls ServerCommand("quit")
              wrapper reads it and restarts with new mode
```

**Files involved:**
- `csgo-wrapper.sh` — Outer loop. Reads `pendingmode.txt`, starts `start.sh` with the correct mode, auto-restarts on exit.
- `start.sh` — Per-boot setup. Deactivates all mode plugins, activates only the ones needed, sets `game_type`/`game_mode`, copies the right mapcycle, then `exec`s srcds.
- `modeswitch.sp` — SourceMod plugin (always loaded). Handles `!modes` command, auto-rotation votes, periodic tips. Writes `pendingmode.txt` and calls `quit` to trigger restart.

**State files** (in `addons/sourcemod/data/`):
- `currentmode.txt` — Written by wrapper on each boot. Read by modeswitch.sp to detect current mode.
- `pendingmode.txt` — Written by modeswitch.sp when a switch is requested. Read and deleted by wrapper.
- `pendingmap.txt` — Optional map override (written by modeswitch.sp, read by wrapper, passed to start.sh).

### Plugin management

All mode-specific plugins live in `plugins/disabled/`. On each boot, `start.sh`:
1. Removes ALL mode plugins from `plugins/` (clean slate)
2. Copies only the plugins needed for the selected mode from `disabled/` to `plugins/`

**Permanent plugins** (always in `plugins/`, never touched):
- `NoLobbyReservation.smx` — Required for client connections
- `modeswitch.smx` — Mode switching, rotation, tips

---

## Game Modes

### Competitive (default)
5v5 MR30, 128 tick, overtime enabled. Standard competitive CS:GO.

| Setting | Value |
|---------|-------|
| game_type / game_mode | 0 / 1 |
| Config | `gamemode_competitive_server.cfg` (auto-exec on map change) |
| Maps | de_dust2, de_mirage, de_inferno, de_overpass, de_nuke, de_ancient, de_vertigo, de_anubis |
| Plugins | weaponpaints, gloves, kento_rankme, rockthevote, mapchooser, nominations |

### Retake
5v4 site retakes with auto-planted bomb and random weapon loadouts.

| Setting | Value |
|---------|-------|
| game_type / game_mode | 0 / 1 |
| Config | `retake.cfg` (via `+servercfgfile`) |
| Maps | Same as competitive |
| Plugins | retakes, retakes_standardallocator + cosmetics + RTV |

**Status:** Partially working. The retakes plugin can be finicky with warmup behavior and bot spawning. May need further tuning.

### Surf
Surf maps with timer, leaderboards, and movement physics.

| Setting | Value |
|---------|-------|
| game_type / game_mode | 3 / 0 (Custom) |
| Config | `surf.cfg` (via `+servercfgfile`) |
| Maps | 31 maps, Tier 1-6 |
| Plugins | SurfTimer, SurfTimer-telefinder, EndTouchFix, st-mapchooser, st-rockthevote, st-nominations, st-voteextend + cosmetics + standard RTV |
| Database | MySQL (MariaDB) — `surftimer` entry in databases.cfg |

**Zones:** Each map needs zones defined manually. Join as admin and type `!zones` to set start/end zones per map.

**Known issue:** Some maps have ramp speed loss (you slow to 0 on certain ramps). This appears to be map-specific, not a config issue. `sv_ramp_fix` does not exist in this engine branch.

### FFA Deathmatch
Free-for-all instant respawn deathmatch. No special plugin needed.

| Setting | Value |
|---------|-------|
| game_type / game_mode | 1 / 2 (DM) |
| Config | `dm.cfg` (via `+servercfgfile`) |
| Maps | de_dust2, de_mirage, de_inferno |
| Plugins | cosmetics + RTV |

**Important:** DM **must** use `game_type 1 game_mode 2` — using Custom (3/0) breaks DM spawn behavior.

### 1v1 Arena
Multi-1v1 dueling arenas. Players rank up/down based on wins.

| Setting | Value |
|---------|-------|
| game_type / game_mode | 3 / 0 (Custom) |
| Config | `arena.cfg` (via `+servercfgfile`) |
| Maps | am_grass2, aim_redline, aim_map |
| Plugins | multi1v1 + cosmetics + RTV |

Arena maps need `am_` or `aim_` prefix and special spawn setups for the multi-1v1 plugin.

### KZ / Climb
Movement/parkour maps with timer, checkpoints, jumpstats, and leaderboards.

| Setting | Value |
|---------|-------|
| game_type / game_mode | 3 / 0 (Custom) |
| Config | `kz.cfg` (via `+servercfgfile`) |
| Maps | kz_beginnerblock_go, kz_checkmate, kz_nature, kz_olympus, kz_reaching |
| Plugins | movementapi + all gokz-* sub-plugins + cosmetics + RTV |
| Database | SQLite (default) or MySQL |

GOKZ sub-plugins: core, hud, jumpstats, localdb, localranks, mode-vanilla, mode-simplekz, mode-kztimer, replays, anticheat, quiet, tips, saveloc, goto, spec, pistol, chat.

**Note:** `gokz-momsurffix` exists but is NOT activated — it causes `CheckParameters` error spam.

---

## In-Game Commands

### For all players

| Command | Description |
|---------|-------------|
| `!ws` | Set weapon skins |
| `!knife` | Set knife skin |
| `!gloves` | Set glove skin |
| `!rtv` | Vote to change map (Rock The Vote) |
| `!nominate` | Nominate a map for next vote |
| `!currentmode` | Show current mode, map, and maps remaining |

### KZ-specific

| Command | Description |
|---------|-------------|
| `!menu` | Main KZ menu (set/load checkpoints) |
| `!options` | Configure KZ settings |
| `!r` | Restart current run |

### Surf-specific

| Command | Description |
|---------|-------------|
| `!r` | Restart (teleport to start) |
| `!s` | Go back to stage start |
| `!zones` | Zone setup (admin only) |

### Admin commands

| Command | Description |
|---------|-------------|
| `!modes` | Open mode vote for all players |
| `!modes surf` | Direct switch to surf (5s countdown, no vote) |
| `!modes dm` | Direct switch to DM |
| `!map de_mirage` | Change map within current mode |
| `!maps` | Open map selection menu |

**`!modes` is admin-only** to prevent restart spam. The auto-rotation vote (which triggers automatically after X maps) is democratic — all players vote.

---

## Mode Rotation

The server automatically rotates modes. After a configurable number of maps, a vote menu appears for all players to choose the next mode.

| Mode | Maps before rotation |
|------|---------------------|
| Competitive | 1 (one full match) |
| Retake | 1 |
| Surf | 1 (30 min timelimit) |
| DM | 2 (2x 10 min) |
| Arena | 1 (30 rounds) |
| KZ | 1 (45 min timelimit) |

When rotation triggers:
1. Players get a 20-second vote menu with all 6 modes
2. Winning mode is announced in chat
3. 5-second countdown with `retry` instructions
4. Server quits, wrapper restarts with the new mode
5. Players type `retry` in console to reconnect

If no one votes, a random different mode is picked.

---

## Adding Maps

### Where to get maps

- **Steam Workshop** (legacy `.bin` ZIPs) — download via Steam client, extract BSP from the `_legacy.bin` archive
- [GameBanana CS:GO Maps](https://gamebanana.com/games/4942)
- [FastDL mirrors](https://fastdl.me/)

**Workshop `+host_workshop_map` does NOT work** with App ID 4465480. You must download `.bsp` files manually.

### Install a map

```bash
# 1. Place the BSP file
cp your_map.bsp /srv/csgo-host/csgo/maps/

# 2. Add to the mode's mapcycle (for RTV)
echo "your_map" >> /srv/csgo-host/csgo/cfg/mapcycle_surf.txt

# 3. Add to modeswitch_maps.cfg (for !maps menu)
#    Edit addons/sourcemod/configs/modeswitch_maps.cfg
#    Add under the correct mode section:
#    "your_map"    "Display Name"
```

### Custom maps + FastDL

Clients need to download custom maps. Set up FastDL:

```bash
# Create a maps directory for FastDL
mkdir -p /srv/fastdl/csgo/maps

# Symlink or copy your custom maps
ln -s /srv/csgo-host/csgo/maps/surf_*.bsp /srv/fastdl/csgo/maps/

# Compress with bzip2 for faster downloads
cd /srv/fastdl/csgo/maps && bzip2 -k *.bsp

# Serve via python HTTP (ephemeral — for testing)
cd /srv/fastdl && python3 -m http.server 27020 &

# Add to server.cfg or mode configs:
# sv_downloadurl "http://YOUR_IP:27020/csgo"
# sv_allowdownload 1
```

For production, use a proper web server (Caddy/nginx) or a systemd service.

---

## Admin Setup

Add yourself as SourceMod admin:

```bash
# Get your Steam2 ID (convert from Steam64 at steamid.io)
# Edit admins_simple.ini:
echo '"STEAM_0:0:YOUR_ID" "99:z"' >> /srv/csgo-host/csgo/addons/sourcemod/configs/admins_simple.ini
```

Flag `99:z` = root admin (all permissions). See [SourceMod admin docs](https://wiki.alliedmods.net/Adding_Admins_(SourceMod)) for granular flags.

The SourceMod `core.cfg` must have these set for skin plugins to work:

```
"FollowCSGOServerGuidelines"    "no"
"BlockBadPlugins"               "no"
```

---

## Plugin Installation (Manual)

If you don't use `setup.sh`, here's how to install each plugin manually.

### PTaH Extension (required for skins)

```bash
cd /srv/csgo-host/csgo/addons/sourcemod
# Download from https://github.com/nicedoc/PTaH/releases
# Extract — the extension may be named PTaH.ext.2.csgo.so (SourceMod auto-detects)
# Place .so in extensions/, gamedata .txt in gamedata/
```

### kgns/WeaponPaints + Gloves

```bash
# Download from https://github.com/kgns/weapons and https://github.com/kgns/gloves
# Place weaponpaints.smx and gloves.smx in plugins/disabled/
# NOTE: kgns/weapons provides BOTH !ws AND !knife in a single plugin
#       There is no separate knife.smx
```

These plugins need `"storage-local"` in databases.cfg (SQLite, already included in the repo's databases.cfg).

### SurfTimer

Requires MySQL. See the [SurfTimer section in setup.sh](#) or:

```bash
# Install MariaDB
sudo apt install mariadb-server lib32z1 -y

# Create database + user
mysql -u root -p -e "
  CREATE DATABASE surftimer;
  CREATE USER 'surftimer'@'127.0.0.1' IDENTIFIED BY 'YOUR_PASSWORD';
  GRANT ALL ON surftimer.* TO 'surftimer'@'127.0.0.1';
  FLUSH PRIVILEGES;
"

# Import schema
mysql -u surftimer -p surftimer < fresh_install.sql

# IMPORTANT: Use 127.0.0.1 (not localhost) in databases.cfg
# localhost uses Unix socket (/tmp/mysql.sock), 127.0.0.1 forces TCP
```

The SourceMod MySQL extension needs `lib32z1` (32-bit zlib) — without it you'll get `libz.so.1: cannot open shared object file`.

### Plugin filename casing

Linux is case-sensitive. These are the correct filenames:
- `SurfTimer.smx` (capital S and T)
- `movementapi.smx` (all lowercase)
- `NoLobbyReservation.smx` (mixed case)
- `gokz-core.smx` (lowercase with dash)

---

## File Structure

```
csgo-server-ospw2026/
|-- setup.sh                         # Full automated VPS setup
|-- start.sh                         # Mode-switching launcher (per boot)
|-- csgo-wrapper.sh                  # Auto-restart wrapper (reads mode files)
|-- update.sh                        # SteamCMD game update script
|-- csgo.service                     # systemd unit (uses wrapper)
|-- modeswitch.sp                    # SourceMod plugin source (v3.0)
|-- modeswitch_maps.cfg              # Per-mode map lists for !maps menu
|-- .env.example                     # Template for credentials
|-- databases.cfg                    # SourceMod database config
|-- server.cfg                       # Base server config (identity, rates)
|-- gamemode_competitive_server.cfg  # Competitive: 128-tick, MR30, overtime
|-- gamemode_casual_server.cfg       # Casual base: for surf/kz modes
|-- retake.cfg                       # Retake: fast rounds, no economy
|-- surf.cfg                         # Surf: airaccel 150, no damage
|-- dm.cfg                           # FFA DM: free-for-all, instant respawn
|-- arena.cfg                        # Arena: plugin-managed 1v1 duels
|-- kz.cfg                           # KZ: airaccel 100, bhop, no damage
|-- mapcycles/
|   |-- mapcycle_competitive.txt     # RTV map pool per mode
|   |-- mapcycle_retake.txt
|   |-- mapcycle_surf.txt
|   |-- mapcycle_dm.txt
|   |-- mapcycle_arena.txt
|   +-- mapcycle_kz.txt
+-- .gitignore
```

---

## Key Gotchas / Lessons Learned

These are hard-won discoveries from setting up CS:GO 2026. Save yourself hours of debugging.

### Server won't start / clients can't connect

- **Docker does NOT work** for srcds — `SteamAPI_Init() failed; create pipe failed` blocks Steam auth inside containers. Run directly on host.
- **NoLobbyReservation is mandatory** — without it, clients silently fail to connect (infinite "Retrying...").
- **App ID must be 4465480** everywhere — `steam.inf`, `steam_appid.txt`, and the GSLT.
- **libgcc_s.so.1 must be removed** from `bin/` — the bundled version conflicts with system libs. SteamCMD restores it on every validate, so `start.sh` removes it on every boot.
- **metamod.vdf path** must be `"../csgo/addons/metamod/bin/server"` — the default relative path from the MetaMod package doesn't work.
- **Delete `linux64/server.so`** in metamod — the engine prefers it over the correct binary.

### Config loading

- **`+servercfgfile <mode>.cfg`** is the correct way to load per-mode configs. NOT `+exec`.
- **`game_type 3 game_mode 0`** (Custom) avoids engine-forced casual behaviors (auto-bots, warmup, map votes). Used for surf, kz, arena.
- **DM must use `game_type 1 game_mode 2`** — Custom mode breaks DM spawns.
- **Retake must use `game_type 0 game_mode 1`** — needs competitive round structure.
- **`gamemode_competitive_server.cfg`** prevents Valve defaults from overriding your settings on map change.

### Plugin gotchas

- **Hot-swapping plugins at runtime doesn't work** — cvars persist, game_type can't change. Server restart is the correct approach.
- **SourceMod can't write to arbitrary paths** — use `BuildPath(Path_SM, ...)` which writes to the SM data directory (`addons/sourcemod/data/`).
- **kgns/weapons provides both `!ws` and `!knife`** in one plugin — there is no separate `knife.smx`.
- **PTaH extension** may be named `PTaH.ext.2.csgo.so` — SourceMod auto-detects the `.2.csgo` suffix, no rename needed.
- **SurfTimer requires MySQL** — `[SurfTimer] Sorry SQLite is not supported`.
- **MySQL extension needs lib32z1** (32-bit zlib) on Ubuntu 24.04.
- **Use `127.0.0.1` not `localhost`** for MySQL host in databases.cfg — `localhost` tries Unix socket (`/tmp/mysql.sock`), TCP is more reliable.
- **Workshop `+host_workshop_map` doesn't work** — appID 730 vs 4465480 mismatch. Download BSPs manually.

### SourceMod admin

- `!modes` was renamed from `!mode` to avoid conflict with GOKZ's `!mode` command (which switches KZ movement modes).
- `!modes` is admin-only (`RegAdminCmd`) to prevent restart spam — the auto-rotation vote is the democratic element.

---

## Operations

### Start / stop

```bash
# Screen (manual)
screen -S csgo /srv/csgo-host/csgo-wrapper.sh competitive
# Detach: Ctrl+A then D
# Reattach: screen -r csgo
# Stop: pkill -9 screen; pkill -9 -f srcds

# systemd (persistent)
sudo systemctl start csgo
sudo systemctl stop csgo
sudo systemctl status csgo
journalctl -u csgo -f
```

### Update game files

```bash
sudo /srv/csgo-host/update.sh
# Stops server, runs SteamCMD, re-applies patches, restarts
```

### Change starting mode (systemd)

```bash
sudo systemctl edit csgo
# Add: [Service]
#      Environment="CSGO_MODE=surf"
sudo systemctl daemon-reload && sudo systemctl restart csgo
```

### Recompile modeswitch plugin

```bash
cd /srv/csgo-host/csgo/addons/sourcemod/scripting
./spcomp modeswitch.sp -o ../plugins/modeswitch.smx
# Restart server to load
```

---

## Known Issues / TODO

- **Retake mode** — warmup doesn't exit properly with bots, needs more plugin work
- **Surf ramp speed** — some maps lose speed on ramps (likely map-specific)
- **Surf zones** — need manual setup per map via `!zones`
- **FastDL** — currently an ephemeral python HTTP server, needs a proper systemd service
- **srcds systemd** — csgo.service works but hasn't been battle-tested with the wrapper
- **Bot configs** — DM(6 bots), Retake(5), Arena(1) configs added but not all tested thoroughly

## Credits

- [eldoradoel/NoLobbyReservation](https://github.com/eldoradoel/NoLobbyReservation) — working fork for 2026 client
- [AlliedModders](https://www.sourcemod.net/) — MetaMod + SourceMod
- [splewis/csgo-retakes](https://github.com/splewis/csgo-retakes) — retake mode
- [splewis/csgo-multi-1v1](https://github.com/splewis/csgo-multi-1v1) — 1v1 arena mode
- [surftimer/SurfTimer](https://github.com/surftimer/SurfTimer) — surf timer + leaderboards
- [KZGlobalTeam/gokz](https://github.com/KZGlobalTeam/gokz) — KZ/climb plugin
- [danzayau/MovementAPI](https://github.com/danzayau/MovementAPI) — GOKZ dependency
- [nicedoc/PTaH](https://github.com/nicedoc/PTaH) — extension for weapon skin plugins
- [kgns/weapons](https://github.com/kgns/weapons) + [kgns/gloves](https://github.com/kgns/gloves) — !ws !knife !gloves
- [CsGoat/csgo-2026-server-setup-script](https://github.com/CsGoat/csgo-2026-server-setup-script) — reference setup
