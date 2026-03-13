#!/bin/bash
# ============================================================================
# ospw CS:GO Server — Full Setup Script
# ============================================================================
# Automates deployment of configs, plugins, databases, maps, systemd service,
# and fixes known issues (databases.cfg, .env quoting, SteamCMD).
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh              # full setup (all steps)
#   sudo ./setup.sh --skip-db    # skip MySQL database setup
#   sudo ./setup.sh --skip-maps  # skip community map downloads
#
# Prerequisites:
#   - Server files installed at /srv/csgo-host/ (via SteamCMD app 740)
#   - MetaMod 1.12 + SourceMod 1.12 installed
#   - NoLobbyReservation compiled and in plugins/
#   - /srv/csgo/.env configured with credentials
#
# Run from the repo directory (where this script lives).
# ============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
DIR="/srv/csgo-host"
CSGO="$DIR/csgo"
CFG="$CSGO/cfg"
SM="$CSGO/addons/sourcemod"
PLUGINS="$SM/plugins"
DISABLED="$PLUGINS/disabled"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="/tmp/csgo-setup-$$"
ENV_FILE="/srv/csgo/.env"

SKIP_DB=false
SKIP_MAPS=false

for arg in "$@"; do
  case "$arg" in
    --skip-db)   SKIP_DB=true ;;
    --skip-maps) SKIP_MAPS=true ;;
    --help|-h)
      echo "Usage: sudo $0 [--skip-db] [--skip-maps]"
      echo ""
      echo "  --skip-db    Skip MySQL database creation"
      echo "  --skip-maps  Skip community map downloads"
      exit 0
      ;;
  esac
done

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

# ============================================================================
# Step 0: Preflight Checks + SteamCMD
# ============================================================================
step "Step 0/8: Preflight Checks"

if [ "$EUID" -ne 0 ]; then
  err "This script must be run as root (sudo)."
  exit 1
fi

if [ ! -d "$CSGO" ]; then
  err "Server directory not found at $CSGO"
  err "Install the server first: steamcmd +force_install_dir $DIR +login anonymous +app_update 740 validate +quit"
  exit 1
fi

if [ ! -d "$SM" ]; then
  err "SourceMod not found at $SM"
  err "Install MetaMod + SourceMod first (see README.md steps 3-4)."
  exit 1
fi

if [ ! -f "$REPO_DIR/start.sh" ] || [ ! -f "$REPO_DIR/surf.cfg" ]; then
  err "Repo files not found. Run this script from the repo directory."
  exit 1
fi

# Check for required tools
for cmd in wget unzip tar; do
  if ! command -v "$cmd" &>/dev/null; then
    err "'$cmd' is required but not installed. Run: apt install $cmd"
    exit 1
  fi
done

# MySQL client check
if ! command -v mysql &>/dev/null; then
  if [ "$SKIP_DB" = true ]; then
    log "mysql client not found (--skip-db set, OK)."
  else
    warn "mysql client not found. Use --skip-db to skip database setup."
    warn "Install with: apt install mariadb-client"
    SKIP_DB=true
  fi
fi

# ── Install SteamCMD if missing ─────────────────────────────────────────────
STEAMCMD=""
for path in /usr/games/steamcmd /usr/bin/steamcmd /home/steam/steamcmd/steamcmd.sh; do
  if [ -x "$path" ]; then
    STEAMCMD="$path"
    break
  fi
done

if [ -z "$STEAMCMD" ]; then
  log "SteamCMD not found. Installing..."
  dpkg --add-architecture i386 2>/dev/null || true
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq steamcmd lib32gcc-s1 lib32stdc++6 2>/dev/null
  if command -v steamcmd &>/dev/null; then
    STEAMCMD="$(command -v steamcmd)"
    log "SteamCMD installed at $STEAMCMD"
  else
    warn "SteamCMD install failed. Game updates won't work."
    warn "Install manually: apt install steamcmd"
  fi
else
  log "SteamCMD found: $STEAMCMD"
fi

log "Server directory: $CSGO"
log "SourceMod directory: $SM"
log "Repo directory: $REPO_DIR"
log "All preflight checks passed."

mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# ============================================================================
# Step 1: Fix .env + Deploy Configs + Fix databases.cfg
# ============================================================================
step "Step 1/8: Configs, .env Fix, databases.cfg Fix"

mkdir -p "$CFG" "$DISABLED"

# ── 1a: Fix .env quoting ────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  log "Checking $ENV_FILE for unquoted special characters..."

  # Backup
  cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"

  # Fix: wrap unquoted values containing shell metacharacters in single quotes.
  # Matches lines like: KEY=value (where value is not already quoted)
  # and contains &, !, *, ?, |, ;, $, (, ), <, >, or spaces.
  FIXED=false
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and blank lines
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
      echo "$line"
      continue
    fi
    # Match KEY=VALUE where VALUE is not quoted
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^\'\"][^\ ]*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Check if value contains shell metacharacters
      if echo "$val" | grep -qP '[&!*?|;$()<>\s]'; then
        echo "${key}='${val}'"
        FIXED=true
        continue
      fi
    fi
    echo "$line"
  done < "$ENV_FILE" > "${ENV_FILE}.fixed"

  if [ "$FIXED" = true ]; then
    mv "${ENV_FILE}.fixed" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "Fixed unquoted special characters in .env"
    warn "Backup saved as ${ENV_FILE}.bak.*"
  else
    rm -f "${ENV_FILE}.fixed"
    log ".env values look OK (no unquoted metacharacters found)."
  fi
else
  warn "$ENV_FILE not found. Copy .env.example to /srv/csgo/.env and fill in values."
fi

# ── 1b: Deploy config files ─────────────────────────────────────────────────
CONFIG_FILES=(
  "server.cfg"
  "gamemode_competitive_server.cfg"
  "gamemode_casual_server.cfg"
  "retake.cfg"
  "surf.cfg"
  "dm.cfg"
  "arena.cfg"
  "kz.cfg"
)

for cfg_file in "${CONFIG_FILES[@]}"; do
  if [ -f "$REPO_DIR/$cfg_file" ]; then
    cp "$REPO_DIR/$cfg_file" "$CFG/$cfg_file"
    log "Deployed: $cfg_file"
  else
    warn "Not found in repo: $cfg_file (skipping)"
  fi
done

# Deploy scripts
cp "$REPO_DIR/start.sh" "$DIR/start.sh"
chmod +x "$DIR/start.sh"
log "Deployed: start.sh"

cp "$REPO_DIR/csgo-wrapper.sh" "$DIR/csgo-wrapper.sh"
chmod +x "$DIR/csgo-wrapper.sh"
log "Deployed: csgo-wrapper.sh"

cp "$REPO_DIR/update.sh" "$DIR/update.sh"
chmod +x "$DIR/update.sh"
log "Deployed: update.sh"

# Deploy per-mode mapcycles (used by RTV/mapchooser)
if [ -d "$REPO_DIR/mapcycles" ]; then
  for mc in "$REPO_DIR"/mapcycles/mapcycle_*.txt; do
    [ -f "$mc" ] && cp "$mc" "$CFG/$(basename "$mc")"
  done
  log "Deployed: per-mode mapcycle files"
fi

# Deploy modeswitch map config
cp "$REPO_DIR/modeswitch_maps.cfg" "$SM/configs/modeswitch_maps.cfg"
log "Deployed: modeswitch_maps.cfg"

# Deploy modeswitch plugin source
cp "$REPO_DIR/modeswitch.sp" "$SM/scripting/modeswitch.sp"
log "Deployed: modeswitch.sp"

# ── 1c: Fix databases.cfg ───────────────────────────────────────────────────
DB_CFG="$SM/configs/databases.cfg"

if [ -f "$DB_CFG" ]; then
  # Check for the known corruption: "property outside section" on early lines
  # This was caused by the Docker entrypoint's sed command.
  if head -5 "$DB_CFG" | grep -qvP '^\s*("Databases"|{|\s*"[^"]+")'; then
    warn "databases.cfg appears corrupted (known Docker issue)."
  fi
  cp "$DB_CFG" "${DB_CFG}.bak.$(date +%s)"
  log "Backed up existing databases.cfg"
fi

# Deploy clean databases.cfg from repo (fixes parse error)
cp "$REPO_DIR/databases.cfg" "$DB_CFG"
log "Deployed clean databases.cfg (fixes parse error)"

log "Config deployment complete."

# ============================================================================
# Step 2: Install Plugins
# ============================================================================
step "Step 2/8: Installing Plugins"

# ── 2a: PTaH Extension (required for weaponpaints, knife, gloves) ───────────
echo ""
log "Installing PTaH extension..."

# PTaH for SourceMod 1.12 / CS:GO Source 1 (Linux)
PTAH_URL="https://github.com/nicedoc/PTaH/releases/latest/download/ptah-linux.zip"
PTAH_ALT_URL="https://ptah.zizt.ru/files/PTaH-V1.1.5-build14-linux.zip"
PTAH_INSTALLED=false

for url in "$PTAH_URL" "$PTAH_ALT_URL"; do
  if wget -q --timeout=30 -O "$TMP/ptah.zip" "$url" 2>/dev/null; then
    unzip -qo "$TMP/ptah.zip" -d "$TMP/ptah"

    # PTaH installs as an extension (.so), not a plugin (.smx)
    find "$TMP/ptah" -name "PTaH.ext.so" -exec cp -f {} "$SM/extensions/" \; 2>/dev/null
    find "$TMP/ptah" -name "ptah.ext.so" -exec cp -f {} "$SM/extensions/PTaH.ext.so" \; 2>/dev/null
    find "$TMP/ptah" -name "PTaH.ext.2.csgo.so" -exec cp -f {} "$SM/extensions/" \; 2>/dev/null
    find "$TMP/ptah" -path "*/gamedata/*" -name "*.txt" -exec cp -f {} "$SM/gamedata/" \; 2>/dev/null

    if ls "$SM/extensions/"*[Pp][Tt]a[Hh]* &>/dev/null; then
      PTAH_INSTALLED=true
      log "PTaH extension installed."
      break
    fi
  fi
done

if [ "$PTAH_INSTALLED" = false ]; then
  warn "Could not download PTaH. Weaponpaints/knife/gloves will not work."
  warn "  Download manually from: https://github.com/nicedoc/PTaH/releases"
  warn "  Place PTaH.ext.so in: $SM/extensions/"
fi

# ── 2b: Retakes ─────────────────────────────────────────────────────────────
echo ""
log "Installing csgo-retakes..."

RETAKES_URL="https://github.com/splewis/csgo-retakes/releases/download/v0.3.4/retakes_0.3.4.zip"
RETAKES_ALT="https://github.com/splewis/csgo-retakes/releases/latest/download/retakes.zip"

RETAKES_INSTALLED=false
for url in "$RETAKES_URL" "$RETAKES_ALT"; do
  if wget -q --timeout=30 -O "$TMP/retakes.zip" "$url" 2>/dev/null; then
    unzip -qo "$TMP/retakes.zip" -d "$TMP/retakes"

    find "$TMP/retakes" -name "retakes.smx" -exec cp -f {} "$DISABLED/" \;
    find "$TMP/retakes" -name "retakes_standardallocator.smx" -exec cp -f {} "$DISABLED/" \;
    find "$TMP/retakes" -path "*/configs/*" -type f -exec cp -n {} "$SM/configs/" \; 2>/dev/null || true
    find "$TMP/retakes" -path "*/translations/*" -type f -exec cp -rn {} "$SM/translations/" \; 2>/dev/null || true

    RETAKES_INSTALLED=true
    log "Retakes installed (plugins in disabled/)."
    break
  fi
done

if [ "$RETAKES_INSTALLED" = false ]; then
  warn "Could not download retakes. Install manually:"
  warn "  https://github.com/splewis/csgo-retakes/releases"
fi

# ── 2c: Multi-1v1 ───────────────────────────────────────────────────────────
echo ""
log "Installing csgo-multi-1v1..."

M1V1_URL="https://github.com/splewis/csgo-multi-1v1/releases/download/1.1.10/multi1v1_1.1.10.zip"
if wget -q --timeout=30 -O "$TMP/multi1v1.zip" "$M1V1_URL" 2>/dev/null; then
  unzip -qo "$TMP/multi1v1.zip" -d "$TMP/multi1v1"

  find "$TMP/multi1v1" -name "multi1v1.smx" -exec cp -f {} "$DISABLED/" \;
  find "$TMP/multi1v1" -name "multi1v1_flashbangs.smx" -exec cp -f {} "$DISABLED/" \; 2>/dev/null
  find "$TMP/multi1v1" -name "multi1v1_kniferounds.smx" -exec cp -f {} "$DISABLED/" \; 2>/dev/null
  find "$TMP/multi1v1" -path "*/configs/*" -type f -exec cp -n {} "$SM/configs/" \; 2>/dev/null || true
  find "$TMP/multi1v1" -path "*/translations/*" -type f -exec cp -rn {} "$SM/translations/" \; 2>/dev/null || true

  log "Multi-1v1 installed (plugins in disabled/)."
else
  warn "Could not download multi-1v1. Install manually:"
  warn "  https://github.com/splewis/csgo-multi-1v1/releases"
fi

# ── 2d: MovementAPI (GOKZ dependency) ───────────────────────────────────────
echo ""
log "Installing MovementAPI (GOKZ dependency)..."

MVAPI_URL="https://github.com/danzayau/MovementAPI/releases/latest/download/MovementAPI.zip"
MVAPI_INSTALLED=false
if wget -q --timeout=30 -O "$TMP/movementapi.zip" "$MVAPI_URL" 2>/dev/null; then
  unzip -qo "$TMP/movementapi.zip" -d "$TMP/movementapi"

  find "$TMP/movementapi" -name "MovementAPI.smx" -exec cp -f {} "$DISABLED/" \;
  find "$TMP/movementapi" -path "*/gamedata/*" -name "*.txt" -exec cp -f {} "$SM/gamedata/" \; 2>/dev/null || true

  MVAPI_INSTALLED=true
  log "MovementAPI installed."
else
  warn "Could not download MovementAPI. GOKZ will not work without it."
  warn "  https://github.com/danzayau/MovementAPI/releases"
fi

# ── 2e: GOKZ ────────────────────────────────────────────────────────────────
echo ""
log "Installing GOKZ..."

GOKZ_URL="https://github.com/KZGlobalTeam/gokz/releases/latest/download/GOKZ-latest.zip"
if wget -q --timeout=30 -O "$TMP/gokz.zip" "$GOKZ_URL" 2>/dev/null; then
  unzip -qo "$TMP/gokz.zip" -d "$TMP/gokz"

  find "$TMP/gokz" -name "gokz-*.smx" -exec cp -f {} "$DISABLED/" \;

  if [ -d "$TMP/gokz/addons/sourcemod/configs" ]; then
    cp -rn "$TMP/gokz/addons/sourcemod/configs/"* "$SM/configs/" 2>/dev/null || true
  fi
  if [ -d "$TMP/gokz/addons/sourcemod/translations" ]; then
    cp -rn "$TMP/gokz/addons/sourcemod/translations/"* "$SM/translations/" 2>/dev/null || true
  fi
  if [ -d "$TMP/gokz/addons/sourcemod/gamedata" ]; then
    cp -rn "$TMP/gokz/addons/sourcemod/gamedata/"* "$SM/gamedata/" 2>/dev/null || true
  fi
  if [ -d "$TMP/gokz/cfg" ]; then
    cp -rn "$TMP/gokz/cfg/"* "$CFG/" 2>/dev/null || true
  fi

  log "GOKZ installed (plugins in disabled/)."
else
  warn "Could not download GOKZ. Install manually:"
  warn "  https://github.com/KZGlobalTeam/gokz/releases"
fi

# ── 2f: SurfTimer ───────────────────────────────────────────────────────────
echo ""
log "Installing SurfTimer..."

SURF_URL="https://github.com/surftimer/SurfTimer/releases/latest/download/SurfTimer.zip"
SURFTIMER_INSTALLED=false
if wget -q --timeout=30 -O "$TMP/surftimer.zip" "$SURF_URL" 2>/dev/null; then
  unzip -qo "$TMP/surftimer.zip" -d "$TMP/surftimer"

  find "$TMP/surftimer" -name "surftimer.smx" -exec cp -f {} "$DISABLED/" \;
  find "$TMP/surftimer" -name "SurfTimer.smx" -exec cp -f {} "$DISABLED/surftimer.smx" \;

  find "$TMP/surftimer" -path "*/configs/*" -type f -exec cp -n {} "$SM/configs/" \; 2>/dev/null || true
  find "$TMP/surftimer" -path "*/translations/*" -type f -exec cp -rn {} "$SM/translations/" \; 2>/dev/null || true
  find "$TMP/surftimer" -path "*/gamedata/*" -type f -exec cp -n {} "$SM/gamedata/" \; 2>/dev/null || true

  find "$TMP/surftimer" -name "fresh_install.sql" -exec cp -f {} "$TMP/surftimer_schema.sql" \; 2>/dev/null

  SURFTIMER_INSTALLED=true
  log "SurfTimer installed (plugin in disabled/)."
else
  warn "Could not download SurfTimer. Install manually:"
  warn "  https://github.com/surftimer/SurfTimer/releases"
fi

# ── 2g: Compile modeswitch plugin ────────────────────────────────────────────
echo ""
log "Compiling modeswitch plugin..."

SPCOMP="$SM/scripting/spcomp"
if [ -x "$SPCOMP" ] && [ -f "$SM/scripting/modeswitch.sp" ]; then
  cd "$SM/scripting"
  if ./spcomp modeswitch.sp -o ../plugins/modeswitch.smx 2>"$TMP/spcomp.log"; then
    log "modeswitch.smx compiled and installed to plugins/ (always loaded)."
  else
    warn "spcomp failed. Errors:"
    cat "$TMP/spcomp.log" 2>/dev/null
    warn "You may need to compile manually:"
    warn "  cd $SM/scripting && ./spcomp modeswitch.sp -o ../plugins/modeswitch.smx"
  fi
  cd "$REPO_DIR"
else
  if [ ! -x "$SPCOMP" ]; then
    warn "spcomp not found at $SPCOMP. Cannot compile modeswitch plugin."
  fi
  if [ ! -f "$SM/scripting/modeswitch.sp" ]; then
    warn "modeswitch.sp not found. Deploy it first."
  fi
  warn "Compile manually: cd $SM/scripting && ./spcomp modeswitch.sp -o ../plugins/modeswitch.smx"
fi

# ── Plugin summary ───────────────────────────────────────────────────────────
echo ""
log "Plugin installation complete. Installed in disabled/:"
ls -1 "$DISABLED/"*.smx 2>/dev/null | while read -r f; do
  echo "    $(basename "$f")"
done

echo ""
log "Permanent plugins in plugins/:"
for p in NoLobbyReservation modeswitch; do
  if [ -f "$PLUGINS/${p}.smx" ]; then
    echo -e "    ${GREEN}OK${NC}  ${p}.smx"
  else
    echo -e "    ${YELLOW}--${NC}  ${p}.smx"
  fi
done

# Check for existing cosmetic plugins already on VPS
echo ""
log "Checking for existing cosmetic plugins..."
for p in weaponpaints gloves knife kento_rankme; do
  if [ -f "$DISABLED/${p}.smx" ] || [ -f "$PLUGINS/${p}.smx" ]; then
    echo -e "    ${GREEN}OK${NC}  ${p}.smx"
  else
    echo -e "    ${YELLOW}--${NC}  ${p}.smx (not found — install separately if needed)"
  fi
done
echo ""

# ============================================================================
# Step 3: MySQL Database Setup
# ============================================================================
step "Step 3/8: Database Setup"

if [ "$SKIP_DB" = true ]; then
  warn "Skipping database setup (--skip-db)."
else
  echo ""
  echo "This will create MySQL databases for SurfTimer and GOKZ."
  echo "You will be prompted for your MySQL root password."
  echo ""
  read -rp "MySQL root user [root]: " MYSQL_ROOT_USER
  MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"

  read -rsp "MySQL root password: " MYSQL_ROOT_PASS
  echo ""

  MYSQL_CMD="mysql -u${MYSQL_ROOT_USER} -p${MYSQL_ROOT_PASS}"

  # Test connection
  if ! $MYSQL_CMD -e "SELECT 1;" &>/dev/null; then
    err "Could not connect to MySQL. Check credentials."
    warn "Skipping database setup. You can re-run with correct credentials later."
    SKIP_DB=true
  fi

  if [ "$SKIP_DB" = false ]; then
    # Generate random passwords
    ST_DB_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)"
    GOKZ_DB_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)"

    # ── SurfTimer database ─────────────────────────────────────────────────
    log "Creating SurfTimer database..."
    $MYSQL_CMD <<SQL
CREATE DATABASE IF NOT EXISTS surftimer CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'surftimer'@'localhost' IDENTIFIED BY '${ST_DB_PASS}';
GRANT ALL PRIVILEGES ON surftimer.* TO 'surftimer'@'localhost';
FLUSH PRIVILEGES;
SQL

    if [ -f "$TMP/surftimer_schema.sql" ]; then
      $MYSQL_CMD surftimer < "$TMP/surftimer_schema.sql" 2>/dev/null && \
        log "SurfTimer schema imported." || \
        warn "SurfTimer schema import failed (tables may already exist)."
    else
      warn "SurfTimer schema SQL not found in release. Import manually from GitHub."
    fi
    log "SurfTimer DB created. User: surftimer / Pass: $ST_DB_PASS"

    # ── GOKZ database ─────────────────────────────────────────────────────
    log "Creating GOKZ database..."
    $MYSQL_CMD <<SQL
CREATE DATABASE IF NOT EXISTS gokz CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'gokz'@'localhost' IDENTIFIED BY '${GOKZ_DB_PASS}';
GRANT ALL PRIVILEGES ON gokz.* TO 'gokz'@'localhost';
FLUSH PRIVILEGES;
SQL
    log "GOKZ DB created. User: gokz / Pass: $GOKZ_DB_PASS"

    # ── Append MySQL entries to databases.cfg ──────────────────────────────
    # The clean base was already deployed in Step 1. Now append MySQL entries.
    if grep -q '"surftimer"' "$DB_CFG" 2>/dev/null; then
      warn "surftimer entry already in databases.cfg — not overwriting."
    else
      # Remove the trailing } and append new entries + closing }
      sed -i '$ d' "$DB_CFG"
      cat >> "$DB_CFG" <<DBEOF

    "surftimer"
    {
        "driver"    "mysql"
        "host"      "localhost"
        "database"  "surftimer"
        "user"      "surftimer"
        "pass"      "${ST_DB_PASS}"
    }

    "gokz"
    {
        "driver"    "mysql"
        "host"      "localhost"
        "database"  "gokz"
        "user"      "gokz"
        "pass"      "${GOKZ_DB_PASS}"
    }
}
DBEOF
      log "Added surftimer + gokz entries to databases.cfg"
    fi

    # Save credentials
    cat > "$DIR/db_credentials.txt" <<CREDS
# CS:GO Server Database Credentials
# Generated by setup.sh on $(date)
# KEEP THIS FILE SECURE — delete after noting passwords

[SurfTimer]
Database: surftimer
User:     surftimer
Password: ${ST_DB_PASS}

[GOKZ]
Database: gokz
User:     gokz
Password: ${GOKZ_DB_PASS}
CREDS
    chmod 600 "$DIR/db_credentials.txt"
    log "Credentials saved to $DIR/db_credentials.txt (chmod 600)"
    warn "Note the passwords above and delete db_credentials.txt when done."
  fi
fi

# ============================================================================
# Step 4: Download Community Maps
# ============================================================================
step "Step 4/8: Map Downloads"

MAPS_DIR="$CSGO/maps"
mkdir -p "$MAPS_DIR"

if [ "$SKIP_MAPS" = true ]; then
  warn "Skipping map downloads (--skip-maps)."
else
  download_map() {
    local mapname="$1"
    local url="$2"

    if [ -f "$MAPS_DIR/${mapname}.bsp" ]; then
      log "Already exists: ${mapname}.bsp (skipping)"
      return 0
    fi

    echo -n "  Downloading ${mapname}... "
    if wget -q --timeout=30 -O "$TMP/${mapname}.bsp.bz2" "$url" 2>/dev/null; then
      if file "$TMP/${mapname}.bsp.bz2" | grep -q "bzip2"; then
        bunzip2 -f "$TMP/${mapname}.bsp.bz2" 2>/dev/null
        if [ -f "$TMP/${mapname}.bsp" ]; then
          mv "$TMP/${mapname}.bsp" "$MAPS_DIR/"
          echo -e "${GREEN}OK${NC}"
          return 0
        fi
      fi
      if file "$TMP/${mapname}.bsp.bz2" | grep -q "data"; then
        mv "$TMP/${mapname}.bsp.bz2" "$MAPS_DIR/${mapname}.bsp"
        echo -e "${GREEN}OK${NC}"
        return 0
      fi
    fi

    if wget -q --timeout=30 -O "$TMP/${mapname}.bsp" "${url%.bz2}" 2>/dev/null; then
      if [ -s "$TMP/${mapname}.bsp" ]; then
        mv "$TMP/${mapname}.bsp" "$MAPS_DIR/"
        echo -e "${GREEN}OK${NC}"
        return 0
      fi
    fi

    echo -e "${YELLOW}FAILED${NC} (download manually)"
    return 1
  }

  MISSING_MAPS=()
  MIRRORS=(
    "https://fastdl.me/csgo/maps"
    "https://dl.serveme.tf/maps"
  )

  # ── Surf maps ────────────────────────────────────────────────────────────
  echo ""
  log "Downloading surf maps..."
  SURF_MAPS=(
    # Tier 1
    surf_beginner surf_utopia_v3 surf_rookie surf_easy surf_whoknows
    # Tier 2
    surf_mesa surf_kitsune surf_greatriver_fix surf_aircontrol_nbv surf_sinsane surf_lux
    # Tier 3
    surf_rebel_resistance_final surf_forbidden_ways surf_exile_go surf_year3000 surf_blossom surf_ace
    # Tier 4
    surf_lt_omnific surf_calycate surf_elysium surf_catalyst surf_me
    # Tier 5
    surf_aeron surf_euphoria surf_nac surf_overgrowth surf_process2
    # Tier 6
    surf_bioshock surf_nyc surf_spacejam surf_amplitude surf_nibiru
  )
  for mapname in "${SURF_MAPS[@]}"; do
    if [ -f "$MAPS_DIR/${mapname}.bsp" ]; then
      log "Already exists: ${mapname}.bsp"
      continue
    fi
    downloaded=false
    for mirror in "${MIRRORS[@]}"; do
      if download_map "$mapname" "${mirror}/${mapname}.bsp.bz2"; then
        downloaded=true
        break
      fi
    done
    [ "$downloaded" = false ] && MISSING_MAPS+=("$mapname")
  done

  # ── KZ maps ──────────────────────────────────────────────────────────────
  echo ""
  log "Downloading KZ maps..."
  for mapname in kz_beginnerblock_go kz_checkmate kz_nature kz_olympus kz_reaching; do
    if [ -f "$MAPS_DIR/${mapname}.bsp" ]; then
      log "Already exists: ${mapname}.bsp"
      continue
    fi
    downloaded=false
    for mirror in "${MIRRORS[@]}"; do
      if download_map "$mapname" "${mirror}/${mapname}.bsp.bz2"; then
        downloaded=true
        break
      fi
    done
    [ "$downloaded" = false ] && MISSING_MAPS+=("$mapname")
  done

  # ── Arena maps ───────────────────────────────────────────────────────────
  echo ""
  log "Downloading 1v1 arena maps..."
  for mapname in am_grass2 am_redline am_plain; do
    if [ -f "$MAPS_DIR/${mapname}.bsp" ]; then
      log "Already exists: ${mapname}.bsp"
      continue
    fi
    downloaded=false
    for mirror in "${MIRRORS[@]}"; do
      if download_map "$mapname" "${mirror}/${mapname}.bsp.bz2"; then
        downloaded=true
        break
      fi
    done
    [ "$downloaded" = false ] && MISSING_MAPS+=("$mapname")
  done

  # Report
  echo ""
  if [ ${#MISSING_MAPS[@]} -gt 0 ]; then
    warn "Could not download these maps automatically:"
    for m in "${MISSING_MAPS[@]}"; do echo "    - ${m}.bsp"; done
    echo ""
    warn "Download manually from: https://gamebanana.com/games/4942"
    warn "Place .bsp files in: $MAPS_DIR/"
  else
    log "All maps downloaded successfully."
  fi
fi

# ============================================================================
# Step 5: systemd Service (auto-restart on reboot)
# ============================================================================
step "Step 5/8: systemd Service"

SERVICE_FILE="/etc/systemd/system/csgo.service"

if [ -f "$REPO_DIR/csgo.service" ]; then
  cp "$REPO_DIR/csgo.service" "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable csgo.service 2>/dev/null

  log "Deployed csgo.service and enabled on boot."
  log "  Start:   systemctl start csgo"
  log "  Stop:    systemctl stop csgo"
  log "  Status:  systemctl status csgo"
  log "  Logs:    journalctl -u csgo -f"
  echo ""
  log "Default mode: competitive. To change:"
  log "  Edit /etc/systemd/system/csgo.service -> Environment=\"CSGO_MODE=surf\""
  log "  Then: systemctl daemon-reload && systemctl restart csgo"
else
  warn "csgo.service not found in repo. Skipping systemd setup."
fi

# ============================================================================
# Step 6: Fix Permissions
# ============================================================================
step "Step 6/8: Fixing Permissions"

chmod +x "$DIR/start.sh" "$DIR/csgo-wrapper.sh" "$DIR/update.sh"
log "Scripts marked executable."

if id "oskar" &>/dev/null; then
  chown -R oskar:oskar "$CFG/" 2>/dev/null || true
  chown -R oskar:oskar "$SM/plugins/" 2>/dev/null || true
  chown -R oskar:oskar "$SM/configs/" 2>/dev/null || true
  chown -R oskar:oskar "$SM/extensions/" 2>/dev/null || true
  chown -R oskar:oskar "$SM/gamedata/" 2>/dev/null || true
  chown -R oskar:oskar "$SM/translations/" 2>/dev/null || true
  chown oskar:oskar "$DIR/start.sh" "$DIR/csgo-wrapper.sh" "$DIR/update.sh" 2>/dev/null || true
  log "Ownership set to oskar for all server files."
else
  warn "User 'oskar' not found. Verify file ownership manually."
fi

# ============================================================================
# Step 7: Verification
# ============================================================================
step "Step 7/8: Verification"

echo ""
ISSUES=0

# ── Configs ──────────────────────────────────────────────────────────────────
log "Config files:"
for cfg_file in "${CONFIG_FILES[@]}"; do
  if [ -f "$CFG/$cfg_file" ]; then
    echo -e "    ${GREEN}OK${NC}  $cfg_file"
  else
    echo -e "    ${RED}MISSING${NC}  $cfg_file"
    ((ISSUES++))
  fi
done
echo ""

# ── databases.cfg ────────────────────────────────────────────────────────────
log "databases.cfg:"
if [ -f "$DB_CFG" ]; then
  # Quick parse check: first non-blank, non-comment line should be "Databases"
  first_line=$(grep -m1 -vP '^\s*$' "$DB_CFG")
  if [[ "$first_line" == *'"Databases"'* ]]; then
    echo -e "    ${GREEN}OK${NC}  Valid structure"
  else
    echo -e "    ${RED}BAD${NC}  Parse error likely (first line: $first_line)"
    ((ISSUES++))
  fi
else
  echo -e "    ${RED}MISSING${NC}  $DB_CFG"
  ((ISSUES++))
fi
echo ""

# ── Extensions ───────────────────────────────────────────────────────────────
log "Extensions:"
if ls "$SM/extensions/"*[Pp][Tt]a[Hh]* &>/dev/null; then
  echo -e "    ${GREEN}OK${NC}  PTaH"
else
  echo -e "    ${YELLOW}MISSING${NC}  PTaH (weaponpaints/knife/gloves won't work)"
fi
echo ""

# ── Mode plugins ─────────────────────────────────────────────────────────────
log "Mode plugins in disabled/:"
for p in retakes.smx retakes_standardallocator.smx multi1v1.smx surftimer.smx MovementAPI.smx gokz-core.smx; do
  if [ -f "$DISABLED/$p" ]; then
    echo -e "    ${GREEN}OK${NC}  $p"
  else
    echo -e "    ${RED}MISSING${NC}  $p"
    ((ISSUES++))
  fi
done
echo ""

# ── Permanent plugins ────────────────────────────────────────────────────────
log "Permanent plugins:"
for p in NoLobbyReservation modeswitch; do
  if [ -f "$PLUGINS/${p}.smx" ]; then
    echo -e "    ${GREEN}OK${NC}  ${p}.smx"
  else
    if [ "$p" = "NoLobbyReservation" ]; then
      echo -e "    ${RED}MISSING${NC}  ${p}.smx (REQUIRED for connections)"
      ((ISSUES++))
    else
      echo -e "    ${YELLOW}MISSING${NC}  ${p}.smx (compile with spcomp)"
    fi
  fi
done
echo ""

# ── Maps ─────────────────────────────────────────────────────────────────────
log "Community maps:"
for prefix in "surf_" "kz_" "am_"; do
  count=$(find "$MAPS_DIR" -name "${prefix}*.bsp" 2>/dev/null | wc -l)
  echo "    ${prefix}* : ${count} map(s)"
done
echo ""

# ── Databases ────────────────────────────────────────────────────────────────
if [ "$SKIP_DB" = false ] && command -v mysql &>/dev/null; then
  log "MySQL databases:"
  for db in surftimer gokz; do
    if mysql -u"${MYSQL_ROOT_USER:-root}" -p"${MYSQL_ROOT_PASS:-}" -e "USE $db;" 2>/dev/null; then
      echo -e "    ${GREEN}OK${NC}  $db"
    else
      echo -e "    ${RED}MISSING${NC}  $db"
    fi
  done
  echo ""
fi

# ── SteamCMD ─────────────────────────────────────────────────────────────────
log "SteamCMD:"
if [ -n "${STEAMCMD:-}" ] && [ -x "$STEAMCMD" ]; then
  echo -e "    ${GREEN}OK${NC}  $STEAMCMD"
else
  echo -e "    ${YELLOW}MISSING${NC}  (game updates won't work)"
fi
echo ""

# ── systemd ──────────────────────────────────────────────────────────────────
log "systemd service:"
if systemctl is-enabled csgo &>/dev/null; then
  echo -e "    ${GREEN}OK${NC}  csgo.service (enabled)"
else
  echo -e "    ${YELLOW}--${NC}  csgo.service (not enabled)"
fi
echo ""

# ── .env ─────────────────────────────────────────────────────────────────────
log ".env file:"
if [ -f "$ENV_FILE" ]; then
  # Source and check
  (
    set +u
    source "$ENV_FILE" 2>/dev/null
    if [ -n "${RCON_PASSWORD:-}" ]; then
      echo -e "    ${GREEN}OK${NC}  RCON_PASSWORD is set"
    else
      echo -e "    ${RED}BAD${NC}  RCON_PASSWORD is empty (check quoting)"
    fi
    if [ -n "${SRCDS_TOKEN:-}" ]; then
      echo -e "    ${GREEN}OK${NC}  SRCDS_TOKEN is set"
    else
      echo -e "    ${YELLOW}--${NC}  SRCDS_TOKEN is empty (LAN-only mode)"
    fi
  )
else
  echo -e "    ${RED}MISSING${NC}  $ENV_FILE"
fi

# ============================================================================
# Step 8: Summary
# ============================================================================
step "Step 8/8: Done"

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
if [ "$ISSUES" -eq 0 ]; then
  echo -e "${GREEN}  Setup complete — no issues found!${NC}"
else
  echo -e "${YELLOW}  Setup complete — $ISSUES issue(s) need attention (see above)${NC}"
fi
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Start with screen (ad-hoc, with auto-restart wrapper):"
echo "    screen -S csgo $DIR/csgo-wrapper.sh              # competitive (default)"
echo "    screen -S csgo $DIR/csgo-wrapper.sh surf         # surf"
echo "    screen -S csgo $DIR/csgo-wrapper.sh retake       # retake"
echo "    screen -S csgo $DIR/csgo-wrapper.sh dm           # deathmatch"
echo "    screen -S csgo $DIR/csgo-wrapper.sh arena        # 1v1 arena"
echo "    screen -S csgo $DIR/csgo-wrapper.sh kz           # KZ / climb"
echo ""
echo "  Start with systemd (auto-restarts, survives reboot):"
echo "    systemctl start csgo"
echo "    journalctl -u csgo -f                     # view logs"
echo ""
echo "  Update game files:"
echo "    sudo $DIR/update.sh"
echo ""
echo "  Connect: connect $(grep -oP 'net_public_adr \K[^ ]+' "$DIR/start.sh" 2>/dev/null || echo '<YOUR_IP>'):27015"
echo ""

if [ ${#MISSING_MAPS[@]:-0} -gt 0 ] 2>/dev/null; then
  warn "Some maps need manual download. See above."
fi
if [ "$SKIP_DB" = true ]; then
  warn "Database setup was skipped. Run again without --skip-db when ready."
fi
