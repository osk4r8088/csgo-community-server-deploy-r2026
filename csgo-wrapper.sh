#!/bin/bash
# ============================================================================
# ospw CS:GO Server — Auto-Restart Wrapper
# ============================================================================
# Usage:  ./csgo-wrapper.sh [initial-mode]
#
# Starts the server and auto-restarts when it exits (e.g. after !mode switch).
# Reads /srv/csgo/.pendingmode to determine the next mode.
# Reads /srv/csgo/.pendingmap for optional map override.
#
# Deploy: /srv/csgo-host/csgo-wrapper.sh
# Run:    screen -S csgo /srv/csgo-host/csgo-wrapper.sh competitive
# ============================================================================

INITIAL_MODE="${1:-competitive}"
STATEDIR="/srv/csgo-host/csgo/addons/sourcemod/data"

# Write initial mode as current
echo "$INITIAL_MODE" > "$STATEDIR/currentmode.txt"

while true; do
    # Check for pending mode switch
    if [ -f "$STATEDIR/pendingmode.txt" ]; then
        MODE=$(head -1 "$STATEDIR/pendingmode.txt" | tr -d '[:space:]')
        rm -f "$STATEDIR/pendingmode.txt"
    else
        MODE=$(head -1 "$STATEDIR/currentmode.txt" 2>/dev/null | tr -d '[:space:]')
        MODE="${MODE:-$INITIAL_MODE}"
    fi

    # Check for pending map override
    MAP_OVERRIDE=""
    if [ -f "$STATEDIR/pendingmap.txt" ]; then
        MAP_OVERRIDE=$(head -1 "$STATEDIR/pendingmap.txt" | tr -d '[:space:]')
        rm -f "$STATEDIR/pendingmap.txt"
    fi

    # Write current mode (modeswitch.sp reads this)
    echo "$MODE" > "$STATEDIR/currentmode.txt"

    echo ""
    echo "========================================"
    echo "  Starting CS:GO — Mode: $MODE"
    [ -n "$MAP_OVERRIDE" ] && echo "  Map override: $MAP_OVERRIDE"
    echo "  $(date)"
    echo "========================================"
    echo ""

    # Kill any stale processes
    pkill -9 -f srcds 2>/dev/null
    sleep 1

    # Start server (start.sh uses exec, so this blocks until server exits)
    if [ -n "$MAP_OVERRIDE" ]; then
        # Pass map override via env var (start.sh can read it)
        MAP_OVERRIDE="$MAP_OVERRIDE" /srv/csgo-host/start.sh "$MODE"
    else
        /srv/csgo-host/start.sh "$MODE"
    fi

    EXIT_CODE=$?
    echo ""
    echo "[Wrapper] Server exited (code $EXIT_CODE). Restarting in 3 seconds..."
    echo "[Wrapper] Press Ctrl+C to stop."
    sleep 3
done
