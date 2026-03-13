#!/bin/bash
# ============================================================================
# ospw CS:GO Server — Mode-Switching Launcher
# ============================================================================
# Usage:  ./start.sh <mode>
#
# Modes:  competitive  (default)  — 5v5 MR30, 128 tick
#         retake                   — 5v4 site retakes
#         surf                     — surf maps with timer
#         dm                       — free-for-all deathmatch
#         arena                    — multi-1v1 arenas
#         kz                       — KZ / climb with timer
#
# Deploy: /srv/csgo-host/start.sh
# ============================================================================

set -euo pipefail

# ── Source credentials ─────────────────────────────────────────────────────
ENV_FILE="/srv/csgo/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "[ERROR] $ENV_FILE not found. Copy .env.example and fill in values."
  exit 1
fi
source "$ENV_FILE"

# Sanity check: warn if critical vars are empty (likely unquoted special chars)
if [ -z "${RCON_PASSWORD:-}" ]; then
  echo "[WARNING] RCON_PASSWORD is empty after sourcing .env"
  echo "  This usually means special characters (&, !, *) are not quoted."
  echo "  Fix: wrap the value in single quotes in $ENV_FILE"
  echo "  Example: RCON_PASSWORD='W4d96&2?!V*N'"
fi
if [ -z "${SRCDS_TOKEN:-}" ]; then
  echo "[WARNING] SRCDS_TOKEN is empty. Server will be LAN-only."
fi

DIR="/srv/csgo-host"
CSGO="$DIR/csgo"
PLUGINS="$CSGO/addons/sourcemod/plugins"
MODE="${1:-competitive}"
WORKSHOP_ID=""   # Set per-mode for workshop maps (uses +host_workshop_map instead of +map)
MAP_OVERRIDE="${MAP_OVERRIDE:-}"  # Optional map override from csgo-wrapper.sh

# ── Pre-boot fixes (SteamCMD validate restores these) ──
rm -f "$DIR/bin/libgcc_s.so.1"
sed -i 's/appID=730/appID=4465480/g' "$CSGO/steam.inf"
echo "4465480" > "$DIR/steam_appid.txt"

# ── Plugin management ──────────────────────────────────────────────────────
# All mode-specific plugins live in plugins/disabled/.
# Each mode activates only the plugins it needs.
# Permanent plugins (always in plugins/): NoLobbyReservation, modeswitch

activate_plugins() {
  # Move requested plugins from disabled/ to plugins/
  for plugin in "$@"; do
    if [ -f "$PLUGINS/disabled/${plugin}.smx" ]; then
      cp "$PLUGINS/disabled/${plugin}.smx" "$PLUGINS/${plugin}.smx"
      echo "  [+] Activated: $plugin"
    else
      echo "  [!] Not found: disabled/${plugin}.smx (skip)"
    fi
  done
}

deactivate_mode_plugins() {
  # Remove any mode-specific plugins that were previously activated.
  # This list covers ALL mode plugins across ALL modes.
  local mode_plugins=(
    # Retake
    retakes retakes_standardallocator retakes_sitepicker
    # Surf (SurfTimer + helpers + its own RTV)
    SurfTimer SurfTimer-telefinder EndTouchFix
    st-mapchooser st-rockthevote st-nominations st-voteextend
    # 1v1 Arena
    multi1v1 multi1v1_flashbangs multi1v1_kniferounds
    # KZ / GOKZ
    gokz-core gokz-hud gokz-jumpstats gokz-localdb gokz-localranks
    gokz-mode-vanilla gokz-mode-simplekz gokz-mode-kztimer
    gokz-global gokz-replays gokz-anticheat gokz-quiet gokz-tips
    gokz-saveloc gokz-goto gokz-spec gokz-pistol gokz-chat
    movementapi
    # Cosmetic (all modes)
    weaponpaints gloves
    # Map voting (all modes)
    rockthevote mapchooser nominations
    # Stats
    kento_rankme
  )
  for plugin in "${mode_plugins[@]}"; do
    rm -f "$PLUGINS/${plugin}.smx"
  done
}

# Clean slate: remove any mode plugins from a previous run
deactivate_mode_plugins

# ── Mode definitions ───────────────────────────────────────────────────────
case "$MODE" in

  competitive)
    echo ">> Starting: COMPETITIVE (5v5, 128 tick, MR30)"
    GAME_TYPE=0
    GAME_MODE=1
    MAP="de_dust2"
    MAPGROUP="mg_active"
    MAXPLAYERS=10
    EXTRA_ARGS=""
    activate_plugins weaponpaints gloves kento_rankme rockthevote mapchooser nominations
    ;;

  retake)
    echo ">> Starting: RETAKE"
    GAME_TYPE=0
    GAME_MODE=1
    MAP="de_dust2"
    MAPGROUP="mg_active"
    MAXPLAYERS=9
    EXTRA_ARGS="+servercfgfile retake.cfg"
    activate_plugins retakes retakes_standardallocator weaponpaints gloves kento_rankme rockthevote mapchooser nominations
    ;;

  surf)
    echo ">> Starting: SURF"
    GAME_TYPE=3
    GAME_MODE=0
    MAP="surf_mesa"
    MAPGROUP="mg_active"
    MAXPLAYERS=24
    EXTRA_ARGS="+servercfgfile surf.cfg"
    activate_plugins SurfTimer SurfTimer-telefinder EndTouchFix \
      st-mapchooser st-rockthevote st-nominations st-voteextend \
      rockthevote mapchooser nominations \
      weaponpaints gloves
    ;;

  dm)
    echo ">> Starting: FFA DEATHMATCH"
    GAME_TYPE=1
    GAME_MODE=2
    MAP="de_dust2"
    MAPGROUP="mg_active"
    MAXPLAYERS=16
    EXTRA_ARGS="+servercfgfile dm.cfg"
    activate_plugins weaponpaints gloves rockthevote mapchooser nominations
    ;;

  arena)
    echo ">> Starting: 1v1 ARENA"
    GAME_TYPE=3
    GAME_MODE=0
    MAP="am_grass2"
    MAPGROUP="mg_active"
    MAXPLAYERS=20
    EXTRA_ARGS="+servercfgfile arena.cfg"
    activate_plugins multi1v1 weaponpaints gloves rockthevote mapchooser nominations
    ;;

  kz)
    echo ">> Starting: KZ / CLIMB"
    GAME_TYPE=3
    GAME_MODE=0
    MAP="kz_beginnerblock_go"
    MAPGROUP="mg_active"
    MAXPLAYERS=16
    EXTRA_ARGS="+servercfgfile kz.cfg"
    activate_plugins \
      movementapi \
      gokz-core gokz-hud gokz-jumpstats gokz-localdb gokz-localranks \
      gokz-mode-vanilla gokz-mode-simplekz gokz-mode-kztimer \
      gokz-replays gokz-anticheat gokz-quiet gokz-tips \
      gokz-saveloc gokz-goto gokz-spec gokz-pistol gokz-chat \
      weaponpaints gloves rockthevote mapchooser nominations
    ;;

  *)
    echo "Unknown mode: $MODE"
    echo ""
    echo "Usage: $0 <mode>"
    echo ""
    echo "  competitive   5v5 MR30, 128 tick (default)"
    echo "  retake        5v4 site retakes"
    echo "  surf          surf maps with timer"
    echo "  dm            free-for-all deathmatch"
    echo "  arena         multi-1v1 arenas"
    echo "  kz            KZ / climb with timer"
    exit 1
    ;;

esac

# ── Map override from wrapper (e.g. !mode selected a specific map) ────────
if [ -n "$MAP_OVERRIDE" ]; then
  MAP="$MAP_OVERRIDE"
  echo ">> Map override: $MAP_OVERRIDE"
fi

# ── Per-mode map cycle (for RTV / mapchooser) ────────────────────────────
MAPCYCLE="$CSGO/cfg/mapcycle_${MODE}.txt"
if [ -f "$MAPCYCLE" ]; then
  cp "$MAPCYCLE" "$CSGO/mapcycle.txt"
  echo ">> Map cycle: mapcycle_${MODE}.txt"
else
  echo ">> [!] No mapcycle_${MODE}.txt found — RTV will use default mapcycle.txt"
fi

echo ">> Map: $MAP | Max players: $MAXPLAYERS"
if [ -n "$WORKSHOP_ID" ]; then
  echo ">> Workshop ID: $WORKSHOP_ID"
fi
echo ""

# ── Build map launch args ────────────────────────────────────────────────
if [ -n "$WORKSHOP_ID" ]; then
  MAP_ARGS="+host_workshop_map $WORKSHOP_ID"
else
  MAP_ARGS="+map $MAP"
fi

# ── Build authkey arg (enables workshop map downloads) ───────────────────
AUTHKEY_ARG=""
if [ -n "${STEAM_API_KEY:-}" ]; then
  AUTHKEY_ARG="-authkey $STEAM_API_KEY"
else
  if [ -n "$WORKSHOP_ID" ]; then
    echo "[WARNING] STEAM_API_KEY not set — workshop map loading may fail."
    echo "  Get a key at: https://steamcommunity.com/dev/apikey"
  fi
fi

# ── Launch ─────────────────────────────────────────────────────────────────
exec "$DIR/srcds_run" \
  -game csgo \
  -console \
  -tickrate 128 \
  -port 27015 \
  +game_type "$GAME_TYPE" \
  +game_mode "$GAME_MODE" \
  +mapgroup "$MAPGROUP" \
  $MAP_ARGS \
  -maxplayers_override "$MAXPLAYERS" \
  +sv_password "$SERVER_PASSWORD" \
  +rcon_password "$RCON_PASSWORD" \
  +hostname "ospw csgo" \
  -ip 0.0.0.0 \
  +net_public_adr 194.163.151.122 \
  -net_port_try 1 \
  +sv_lan 0 \
  +sv_setsteamaccount "$SRCDS_TOKEN" \
  $AUTHKEY_ARG \
  $EXTRA_ARGS
