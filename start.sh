#!/bin/bash
source /srv/csgo/.env
DIR="/srv/csgo-host"
rm -f "$DIR/bin/libgcc_s.so.1"
sed -i 's/appID=730/appID=4465480/g' "$DIR/csgo/steam.inf"
echo "4465480" > "$DIR/steam_appid.txt"
exec "$DIR/srcds_run" \
  -game csgo \
  -console \
  -port 27015 \
  +game_type 0 \
  +game_mode 1 \
  +mapgroup mg_active \
  +map de_dust2 \
  -maxplayers_override 10 \
  +sv_password "$SERVER_PASSWORD" \
  +rcon_password "$RCON_PASSWORD" \
  +hostname "ospw csgo" \
  -ip 0.0.0.0 \
  +net_public_adr 194.163.151.122 \
  -net_port_try 1 \
  +sv_lan 0 \
  +sv_setsteamaccount "$SRCDS_TOKEN"
