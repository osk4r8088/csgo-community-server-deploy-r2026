#!/bin/bash
# ============================================================================
# ospw CS:GO Server — SteamCMD Update Script
# ============================================================================
# Downloads the latest CS:GO server files from Valve via SteamCMD.
# Stops the server before updating and restarts it afterwards.
#
# Usage:  sudo ./update.sh
#         sudo ./update.sh --no-restart   # update only, don't restart
#
# Deploy: /srv/csgo-host/update.sh
# ============================================================================

set -euo pipefail

DIR="/srv/csgo-host"
STEAMCMD="/usr/games/steamcmd"
NO_RESTART=false

for arg in "$@"; do
  case "$arg" in
    --no-restart) NO_RESTART=true ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Preflight ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  err "Run as root: sudo $0"
  exit 1
fi

if ! command -v "$STEAMCMD" &>/dev/null; then
  # Try common alternative paths
  for alt in /usr/bin/steamcmd /home/steam/steamcmd/steamcmd.sh; do
    if [ -x "$alt" ]; then
      STEAMCMD="$alt"
      break
    fi
  done
  if ! command -v "$STEAMCMD" &>/dev/null && [ ! -x "$STEAMCMD" ]; then
    err "SteamCMD not found. Install with: sudo apt install steamcmd"
    exit 1
  fi
fi

# ── Stop server ──────────────────────────────────────────────────────────────
log "Stopping CS:GO server..."

if systemctl is-active --quiet csgo 2>/dev/null; then
  systemctl stop csgo
  log "Stopped via systemd."
  STARTED_BY="systemd"
elif screen -list | grep -q "csgo"; then
  screen -S csgo -X stuff "quit\n"
  sleep 5
  log "Sent quit to screen session."
  STARTED_BY="screen"
else
  warn "No running server found. Proceeding with update."
  STARTED_BY="none"
fi

# Wait for srcds to fully stop
sleep 3

# ── Update ───────────────────────────────────────────────────────────────────
log "Running SteamCMD update (app 740)..."
echo ""

"$STEAMCMD" \
  +force_install_dir "$DIR" \
  +login anonymous \
  +app_update 740 validate \
  +quit

echo ""
log "SteamCMD update complete."

# ── Post-update patches ─────────────────────────────────────────────────────
# SteamCMD validate restores files that start.sh normally patches on boot.
# We do it here too for safety.
log "Applying post-update patches..."

rm -f "$DIR/bin/libgcc_s.so.1"
log "  Removed bundled libgcc_s.so.1"

sed -i 's/appID=730/appID=4465480/g' "$DIR/csgo/steam.inf"
echo "4465480" > "$DIR/steam_appid.txt"
log "  Patched App ID to 4465480"

# ── Restart ──────────────────────────────────────────────────────────────────
if [ "$NO_RESTART" = true ]; then
  log "Update complete. Server NOT restarted (--no-restart)."
  exit 0
fi

log "Restarting server..."

if [ "$STARTED_BY" = "systemd" ] || systemctl is-enabled --quiet csgo 2>/dev/null; then
  systemctl start csgo
  sleep 3
  if systemctl is-active --quiet csgo; then
    log "Server restarted via systemd."
  else
    err "systemd failed to start csgo. Check: journalctl -u csgo -n 50"
    exit 1
  fi
elif [ "$STARTED_BY" = "screen" ]; then
  # Restart in screen with the previous mode (default: competitive)
  LAST_MODE="competitive"
  screen -dmS csgo "$DIR/start.sh" "$LAST_MODE"
  log "Server restarted in screen (mode: $LAST_MODE)."
else
  warn "No previous run method detected. Start manually:"
  warn "  screen -S csgo $DIR/start.sh"
  warn "  or: systemctl start csgo"
fi

echo ""
log "Update complete."
