# CS:GO 2026 Dedicated Server

Hosting a Counter-Strike: Global Offensive dedicated server using Valve's 2026 standalone re-release (App ID 4465480).

## Requirements

- Ubuntu 22.04+ (tested on 24.04)
- 35 GB disk space
- 2+ GB RAM
- SteamCMD
- A GSLT (Game Server Login Token) for app **4465480**
get one at [steamcommunity.com/dev/managegameservers](https://steamcommunity.com/dev/managegameservers)

## Quick Start

### 1. Install SteamCMD and download server files

```bash
sudo apt update && sudo apt install -y lib32gcc-s1 lib32stdc++6 screen
# Install SteamCMD per https://developer.valvesoftware.com/wiki/SteamCMD

steamcmd +force_install_dir /srv/csgo-host +login anonymous +app_update 740 validate +quit
```

### 2. Patch for 2026 standalone client

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

### 4. Install NoLobbyReservation (REQUIRED)

Without this plugin, clients cannot connect at all. The 2026 client uses a lobby reservation system that must be bypassed.

```bash
cd /srv/csgo-host/csgo/addons/sourcemod

# Download from eldoradoel fork (working gamedata)
wget -O nolobby.zip "https://github.com/eldoradoel/NoLobbyReservation/archive/refs/heads/master.zip"
unzip nolobby.zip

# Copy gamedata
cp NoLobbyReservation-master/csgo/addons/sourcemod/gamedata/nolobbyreservation.games.txt gamedata/

# Compile plugin
cp NoLobbyReservation-master/csgo/addons/sourcemod/scripting/nolobbyreservation.sp scripting/NoLobbyReservation.sp
cd scripting
chmod +x spcomp
./spcomp NoLobbyReservation.sp -o ../plugins/NoLobbyReservation.smx

# Clean up
cd .. && rm -rf nolobby.zip NoLobbyReservation-master
```

### 5. Configure

```bash
# Create env file with your credentials
cp .env.example /srv/csgo/.env
nano /srv/csgo/.env   # Fill in SRCDS_TOKEN, passwords

# Copy server config
cp server.cfg /srv/csgo-host/csgo/cfg/server.cfg
```

### 6. Start

```bash
screen -S csgo /srv/csgo-host/start.sh
# Detach: Ctrl+A then D
# Reattach: screen -r csgo
```

### 7. Connect

In your CS:GO client console:

```
connect <YOUR_SERVER_IP>:27015; password <SERVER_PASSWORD>
```

## Key Learnings

- **Docker does NOT work** for CS:GO srcds — `SteamAPI_Init() failed; create pipe failed` blocks all Steam authentication inside containers. Run directly on host.
- **NoLobbyReservation is mandatory** — without it, clients silently fail to connect ("Retrying..." forever).
- **App ID must be 4465480** — both in `steam.inf` and `steam_appid.txt`, and the GSLT must be created for this app ID.
- **libgcc_s.so.1 must be removed** from `bin/` — the bundled version conflicts with the system library and breaks Steam client loading. SteamCMD restores it on every validate, so `start.sh` removes it on every boot.
- **metamod.vdf path** must use `"../csgo/addons/metamod/bin/server"` — the default relative path from the MetaMod package doesn't work.

## File Structure

```
csgo-server/
├── start.sh                 # Launch script (sources .env, patches, starts srcds)
├── server.cfg               # Game settings (128 tick, competitive)
├── .env.example             # Template for credentials
├── addons/
│   ├── metamod.vdf          # MetaMod loader config
│   └── sourcemod/
│       ├── configs/
│       │   └── databases.cfg    # Plugin database configs (SQLite)
│       └── gamedata/
│           └── nolobbyreservation.games.txt  # Memory signatures
├── SESSION_CONTEXT.md       # Detailed deploy log and troubleshooting history
├── VPS_CHEATSHEET.txt       # Quick reference for server ops
└── README.md
```

## Credits

- [CsGoat/csgo-2026-server-setup-script](https://github.com/CsGoat/csgo-2026-server-setup-script) — reference setup
- [eldoradoel/NoLobbyReservation](https://github.com/eldoradoel/NoLobbyReservation) — working fork with updated gamedata
- [AlliedModders](https://www.sourcemod.net/) — MetaMod + SourceMod
