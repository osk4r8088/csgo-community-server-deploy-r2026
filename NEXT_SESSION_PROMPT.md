# CS:GO 2026 Server — Next Session Prompt

Copy everything below this line into a new Claude session to continue development.

---

## Context

I have a CS:GO 2026 multi-mode dedicated server running on my Contabo VPS (Ubuntu 24.04, 8GB RAM, IP 194.163.151.122). The full codebase is at `C:\Users\oskar\Documents\VPS\csgo-server-ospw2026-openclaw\` locally and pushed to GitHub at `osk4r8088/csgo-server-ospw2026` (tag v1.0 on main). I can't give you SSH access — I run all VPS commands manually, you provide commands.

**Read these files first to understand the full architecture and history:**
- `README.md` — How everything works, architecture, commands, gotchas
- `DEVLOG.md` — Full bug history, architecture decisions, plugin inventory, known issues
- `start.sh` — Mode launcher (per-mode plugin activation, game_type settings)
- `csgo-wrapper.sh` — Auto-restart wrapper (reads pendingmode.txt, restarts with new mode)
- `modeswitch.sp` — SourceMod plugin v3.0 (mode switching, rotation votes, tips)
- `setup.sh` — Automated deployment script

## Current State (v1.0, 2026-03-13)

### What works
- 6 modes: competitive, dm, surf, kz, arena, retake (retake mostly broken)
- Restart-based mode switching via wrapper + modeswitch plugin
- Auto-rotation with democratic vote after configurable map limits per mode
- Skins (!ws !knife !gloves) via PTaH + kgns/weapons + kgns/gloves on all modes
- SurfTimer v1.1.4 with MariaDB backend (timer works, zones need manual setup per map)
- GOKZ v3.6.4 + MovementAPI v2.4.3 (timer, checkpoints, jumpstats — all working perfectly)
- RTV/mapchooser/nominations on all modes
- Admin: osk4r (STEAM_0:0:185709410) = root admin "99:z"
- RankMe for competitive/retake
- FastDL: python3 HTTP on :27020 (ephemeral, serves custom map BSPs)

### What's broken / incomplete
- **Retake mode**: stays in warmup, doesn't start properly with bots. Needs investigation — could be plugin version, bot config, or warmup cvar issue
- **Surf ramp speed**: maps, only mesa configured and tested so far, lose speed on ramps (likely map-specific geometry, not config). sv_ramp_fix doesn't exist in this engine
- **Surf zones**: need manual !zones setup per map (admin-only, tedious but required)
- **FastDL**: ephemeral python server, dies on reboot, no rate limiting, no HTTPS
- **csgo.service**: uses wrapper but hasn't been battle-tested with systemd
- **Bot configs**: DM(6), Retake(5), Arena(1) — added but not all verified
- **DM mp_death_drop_gun**: was set to 1 (guns drop), should probably be 0 for cleaner FFA

### Infrastructure
- VPS: Contabo Ubuntu 24.04, user `oskar`
- DNS: Cloudflare (proxy enabled). Domains: ospw.de, oskarschulz.de, oskarschulz.com
- Reverse proxy: Caddy (already running for other services)
- Auth: Authentik at auth.ospw.de
- Other services: Element/Synapse/Coturn (chat.ospw.de), Django dashboard (app.ospw.de), Hugo portfolio (ospw.de)
- MariaDB 10.11 on localhost (surftimer database)
- No backups yet, no monitoring

### Key technical facts
- Server runs at `/srv/csgo-host/` via `screen -S csgo /srv/csgo-host/csgo-wrapper.sh <mode>`
- Config at `/srv/csgo/.env` (SRCDS_TOKEN, passwords, STEAM_API_KEY)
- Docker does NOT work for srcds (SteamAPI IPC fails in container)
- NoLobbyReservation (eldoradoel fork) is REQUIRED for 2026 client connections
- Workshop maps don't work (+host_workshop_map fails, appID 730 vs 4465480 mismatch)
- Custom maps must be BSP files placed in csgo/maps/ and served via FastDL
- `game_type 3 game_mode 0` (Custom) for surf/kz/arena, `game_type 1 game_mode 2` for DM, `game_type 0 game_mode 1` for competitive/retake
- Plugin files in `plugins/disabled/`, start.sh activates per mode
- SourceMod file writes must use `BuildPath(Path_SM, ...)` — can't write to arbitrary paths
- Plugin filename casing matters: SurfTimer.smx, movementapi.smx, NoLobbyReservation.smx

## Goals for this session

### 1. Security Hardening (before going public)
- [ ] **FastDL systemd service** — Replace ephemeral python HTTP with proper systemd unit. Consider serving through Caddy for HTTPS + rate limiting
- [ ] **RCON security** — Add `sv_rcon_banpenalty`, `sv_rcon_maxfailures`, consider IP whitelist via iptables
- [ ] **Firewall audit** — Verify UFW rules: 27015/udp (game), 27015/tcp (RCON), 27020/tcp (FastDL). Block everything else for srcds
- [ ] **SourceMod security** — Verify no public-facing exploits in loaded plugins, check SM version for CVEs
- [ ] **Rate limiting** — Caddy rate limit on FastDL to prevent abuse
- [ ] **Log rotation** — srcds and SourceMod logs can grow unbounded

### 2. DNS + Web Presence
- [ ] **csgo.ospw.de DNS** — A record in Cloudflare pointing to VPS IP (proxy enabled)
- [ ] **Caddy site block** for csgo.ospw.de — Start with a simple static page or redirect
- [ ] **Server info page** — Simple page showing: current mode, current map, player count, connect command, map pool per mode. Could be static HTML updated by a cron script that queries RCON, or a small Flask/Django app
- [ ] **Future**: stats dashboard for different modes, leaderboards, ability to see scoreboards / rating / for comp

### 3. Playability & Maps
- [ ] **Fix retake mode** — Debug warmup issue, test with different bot counts, check if newer retakes plugin version exists
- [ ] **Add more maps** — User mentioned wanting: de_cache for competitive/DM, more KZ maps, more surf maps, more arena maps
- [ ] **Surf zone setup** — Set up zones on the most popular T1-T2 maps at minimum
- [ ] **Test auto-rotation** — Actually play through a full rotation cycle, verify vote system works with 2+ players
- [ ] **Verify bot configs** — Join each mode solo, verify bots spawn with correct counts
- [ ] **DM polish** — Fix mp_death_drop_gun, test FFA with bots, verify weapon buy menu works

### 4. Deployment & Operations
- [ ] **srcds systemd service** — Battle-test csgo.service with the wrapper, verify restart behavior
- [ ] **FastDL systemd** — Proper service for the map download server
- [ ] **VPS reboot** — Still pending from apt upgrade, need to verify everything comes back up cleanly
- [ ] **Backup strategy** — At minimum: MySQL dump + SM data dir + configs. Consider rsync to second location
- [ ] **Monitoring** — Basic: systemd service status alerts. Advanced: Grafana + custom dashboard on app.ospw.de

### 5. Future Features (lower priority)
- [ ] **csgo.ospw.de dashboard** — Live server status, player stats, leaderboards
- [ ] **Discord webhook** — Mode change notifications, player join/leave
- [ ] **Map download automation** — Script to fetch maps from GameBanana/FastDL mirrors
- [ ] **Per-mode MOTD** — Show mode info and commands on connect
- [ ] **Authentik integration** — Admin panel for server management via web

## How I work
- I enter all SSH/VPS commands manually — you provide the commands
- Be concise, no fluff
- Careful with deletions — 100% sure before removing anything
- Cost-conscious — don't burn tokens on excessive research
- I like building custom tools on top of standard stacks
- app.ospw.de (Django) is my main hub for integrations

## Start by
1. Read the repo files I mentioned above to understand the codebase
2. Suggest which tasks to tackle first based on effort/impact
3. Let's go
