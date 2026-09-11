#!/bin/bash
# =============================================================================
#  Shadow Haven Hosting - WARDOGS dedicated server entrypoint
#
#  Mirrors what the BisectHosting "Starbase" wrapper does for WARDOGS:
#    1. (optionally) update the server from Steam at boot
#    2. render Configs/ServerSettings.ini from egg variables
#    3. launch the UE5 server with the egg's STARTUP command
#    4. background auto-update watcher (warns, then gracefully restarts)
#    5. optional 12h recycle restart
#
#  Everything that Bulkhead only hands to approved hosts is an env var:
#    STEAM_USER / STEAM_PASS   licensed Steam account for the private branch
#    SRCDS_APPID               dedicated-server Steam App ID
#    SRCDS_BETAID              beta branch (community_provider_server)
#    SRCDS_BETAPASS            beta password, if Bulkhead issued one
#    PRAGMA_BRANCH             value used in -PatchId=<PRAGMA_BRANCH>_COMMUNITY_<HOST_TAG>
#    BINARY                    server binary name inside Wardogs/Binaries/Linux/
# =============================================================================
set -o pipefail
cd /home/container || exit 1

c_reset='\033[0m'; c_panel='\033[1;33m'; c_steam='\033[0;32m'; c_warn='\033[1;31m'; c_info='\033[0;36m'
panel() { echo -e "${c_panel}[Panel]:${c_reset} $*"; }
steam() { echo -e "${c_steam}[SteamCMD]:${c_reset} $*"; }
warn()  { echo -e "${c_warn}[Warn]:${c_reset} $*"; }
info()  { echo -e "${c_info}[Info]:${c_reset} $*"; }

# ---------------------------------------------------------------------------
# Defaults (egg variables override these)
# ---------------------------------------------------------------------------
: "${SERVER_NAME:=A Shadow Haven Server}"
: "${SERVER_PASS:=}"
: "${MAX_PLAYERS:=100}"
: "${AUTO_UPDATE:=2}"            # 0 = never, 1 = on startup only, 2 = startup + periodic
: "${WARN_TIMER:=60}"            # minutes to wait before an automatic update restart
: "${UPDATE_CHECK_MINUTES:=60}"  # how often the watcher polls Steam
: "${REMOTE_API:=0}"             # 1 = RCON reachable remotely on RCON_PORT, 0 = 127.0.0.1 only
: "${WDRCON_PASSWORD:=}"
: "${RCON_INTERNAL_PORT:=47990}"
: "${RCON_PORT:=$((SERVER_PORT + 1))}"
: "${RECYCLE_HOURS:=12}"         # 0 disables the periodic cleanup restart
: "${SRCDS_APPID:=}"
: "${SRCDS_BETAID:=community_provider_server}"
: "${SRCDS_BETAPASS:=}"
: "${STEAM_USER:=}"
: "${STEAM_PASS:=}"
: "${STEAM_AUTH:=}"
: "${HOST_TAG:=SHADOWHAVEN}"
: "${WORKER_THREADS:=6}"
: "${BINARY:=WardogsServer}"

INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2); exit}')
export INTERNAL_IP

STEAMCMD=/home/container/steamcmd/steamcmd.sh
STEAM_ROOT=/home/container/Steam
MANIFEST="${STEAM_ROOT}/steamapps/appmanifest_${SRCDS_APPID}.acf"
UPDATE_FLAG=/home/container/.update_pending

panel "Shadow Haven WARDOGS wrapper starting (revision 1.0)"
panel "Setting Max Players to ${MAX_PLAYERS}.."
mkdir -p Configs Saved/Logs Saved/RCON .steam/sdk64 .steam/sdk32

# Steam SDK shims the UE5 Steam subsystem looks for (Bisect's image is missing these,
# hence the "Failed to load module .steam/sdk64/steamclient.so" line in their console).
ln -sf /home/container/steamcmd/linux64/steamclient.so /home/container/.steam/sdk64/steamclient.so
ln -sf /home/container/steamcmd/linux32/steamclient.so /home/container/.steam/sdk32/steamclient.so

# ---------------------------------------------------------------------------
# SteamCMD helpers
# ---------------------------------------------------------------------------
steam_login_args() {
  if [[ -n "${STEAM_USER}" ]]; then
    echo "+login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH}"
  else
    echo "+login anonymous"
  fi
}

steam_update() {
  local validate="${1:-}"
  if [[ -z "${SRCDS_APPID}" ]]; then
    warn "SRCDS_APPID is not set - skipping Steam update. Set it to the WARDOGS dedicated-server App ID Bulkhead issued to you."
    return 1
  fi
  if [[ -z "${STEAM_USER}" ]]; then
    warn "STEAM_USER is empty. The '${SRCDS_BETAID}' branch is licensed to approved community providers only; an anonymous login will be refused."
  fi
  if [[ ! -x "${STEAMCMD}" ]]; then
    steam "SteamCMD missing, downloading.."
    mkdir -p steamcmd && curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C steamcmd
  fi
  steam "Steam User set to ${STEAM_USER:+********}${STEAM_USER:-anonymous}"
  steam "Updating app ${SRCDS_APPID} (branch: ${SRCDS_BETAID:-public})${validate:+ with validation}.."
  local beta_args=""
  [[ -n "${SRCDS_BETAID}" ]]   && beta_args+=" -beta ${SRCDS_BETAID}"
  [[ -n "${SRCDS_BETAPASS}" ]] && beta_args+=" -betapassword ${SRCDS_BETAPASS}"
  # shellcheck disable=SC2046
  "${STEAMCMD}" +force_install_dir /home/container \
      $(steam_login_args) \
      +app_update "${SRCDS_APPID}" ${beta_args} ${validate} \
      +quit
  local rc=$?
  [[ ${rc} -ne 0 ]] && warn "SteamCMD exited with code ${rc}"
  echo "${SRCDS_BETAID}" > .install-branch.txt
  return ${rc}
}

local_buildid() {
  [[ -f "${MANIFEST}" ]] && grep -m1 '"buildid"' "${MANIFEST}" | tr -dc '0-9'
}

remote_buildid() {
  # Query Steam for the branch's current build id. Cleared appcache forces a fresh fetch.
  rm -f "${STEAM_ROOT}/appcache/appinfo.vdf" 2>/dev/null
  # shellcheck disable=SC2046
  "${STEAMCMD}" $(steam_login_args) +app_info_update 1 +app_info_print "${SRCDS_APPID}" +quit 2>/dev/null \
    | awk -v br="\"${SRCDS_BETAID:-public}\"" '
        $1==br {inbr=1}
        inbr && $1=="\"buildid\"" {gsub(/"/,"",$2); print $2; exit}
      '
}

# ---------------------------------------------------------------------------
# Boot-time update
# ---------------------------------------------------------------------------
if [[ "${AUTO_UPDATE}" != "0" ]]; then
  steam_update
else
  steam "Skipping Update Check as Auto Update is Disabled.."
fi

# ---------------------------------------------------------------------------
# Render Configs/ServerSettings.ini
#   Only keys the game whitelists (AllowedConfigs) are honoured, so we only touch
#   the ones the panel owns; everything else in the file is the customer's.
# ---------------------------------------------------------------------------
INI=Configs/ServerSettings.ini
if [[ ! -f "${INI}" ]]; then
  panel "No ServerSettings.ini found, writing default.."
  cat > "${INI}" <<'INI_EOF'
;|======================================================================================================|
;| Wardogs Dedicated Server Standalone Config - managed by Shadow Haven Hosting                          |
;| Server name / password / max players / RCON are set from the panel's Startup tab on every boot.       |
;| Everything else (join gates, rotation, balancing) is yours to edit. Restart the server to apply.      |
;|======================================================================================================|

[/Script/WDGame.WDGameSession]
ServerName=
ServerPassword=
ServerMinPlayerCash=0
ServerMaxPlayerCash=0
ServerMinPlayerLevel=0
ServerMaxPlayerLevel=0
ServerImageURL=
MaxReservedSlots=0
+DefaultReservedPlayerIds=00000000000000000
+DefaultBannedPlayerIds=00000000000000000

[MatchState.PreMatch.WaitingForPlayers.PlayerCount]
MinimumRequiredPlayers=20

[MatchState.Playing.KOTH]
ScorePeriod=24

[/Script/WDGame.WDGameStateSession]
bLockOverpopulatedTeamsConfig=true
OverpopulatedTeamThresholdConfig=2

[/Script/WDGame.WDServerMapRotationSettings]
bEnabled=True
RotationMode=Ordered
+RotationEntries=(Map="Kavkazi",Experience="Bakurani_KOTH_01",Lighting="DayEarlyClear",ZoneAlternator="ZoneAlternator.Bakurani.Default.Circle")
+RotationEntries=(Map="Europe",Experience="Madrid_KOTH_01",Lighting="DayEarlyFog",ZoneAlternator="ZoneAlternator.Ozeti.Default.Circle")
+RotationEntries=(Map="NorthAmerica",Experience="Detroit_KOTH_01",Lighting="DayClear",ZoneAlternator="ZoneAlternator.Zestafona.Default.Circle")
+RotationEntries=(Map="Kavkazi",Experience="Bakurani_KOTH_01",Lighting="DayLateClear",ZoneAlternator="ZoneAlternator.Bakurani.Farmland.Circle")
+RotationEntries=(Map="Europe",Experience="Madrid_KOTH_01",Lighting="DayLateGray",ZoneAlternator="ZoneAlternator.Ozeti.Church.Circle")
+RotationEntries=(Map="NorthAmerica",Experience="Detroit_KOTH_01",Lighting="DayLateGrayFog",ZoneAlternator="ZoneAlternator.Zestafona.Houses.Circle")
+RotationEntries=(Map="Kavkazi",Experience="Bakurani_KOTH_01",Lighting="DayEarlyClear",ZoneAlternator="ZoneAlternator.Bakurani.Lumberyard.Circle")
+RotationEntries=(Map="Europe",Experience="Madrid_KOTH_01",Lighting="DayEarlyFog",ZoneAlternator="ZoneAlternator.Ozeti.Farmland.Circle")
+RotationEntries=(Map="NorthAmerica",Experience="Detroit_KOTH_01",Lighting="DayClear",ZoneAlternator="ZoneAlternator.Zestafona.SmallFactory.Circle")
+RotationEntries=(Map="Kavkazi",Experience="Bakurani_KOTH_01",Lighting="DayLateClear",ZoneAlternator="ZoneAlternator.Bakurani.River.Circle")
+RotationEntries=(Map="Europe",Experience="Madrid_KOTH_01",Lighting="DayLateGray",ZoneAlternator="ZoneAlternator.Ozeti.River.Circle")
+RotationEntries=(Map="NorthAmerica",Experience="Detroit_KOTH_01",Lighting="DayLateGrayFog",ZoneAlternator="ZoneAlternator.Zestafona.WaterTreatment.Circle")

[/Script/WDRCON.WDRCONSettings]
bEnabled=true
Port=47990
Password=
BindAddress=127.0.0.1

[/Script/Engine.GameSession]
MaxPlayers=100
INI_EOF
fi

if [[ -z "${WDRCON_PASSWORD}" ]]; then
  WDRCON_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  warn "WDRCON_PASSWORD was empty - generated one for this boot: ${WDRCON_PASSWORD}"
fi
echo -n "${WDRCON_PASSWORD}" > Saved/RCON/ADMIN-PASSWORD.txt

if [[ "${REMOTE_API}" == "1" ]]; then
  RCON_BIND=0.0.0.0; RCON_LISTEN_PORT=${RCON_PORT}
  panel "RCON: remote access enabled on ${RCON_LISTEN_PORT} (restrict it in Configs/APIWhitelist.txt)"
else
  RCON_BIND=127.0.0.1; RCON_LISTEN_PORT=${RCON_INTERNAL_PORT}
  panel "RCON: internal only (127.0.0.1:${RCON_LISTEN_PORT})"
fi
export RCON_LISTEN_PORT RCON_BIND WDRCON_PASSWORD

# set_ini <section-regex> <key> <value>   (replaces the key inside that section only)
set_ini() {
  local sec="$1" key="$2" val="$3"
  grep -qF "[${sec}]" "${INI}" || printf '\n[%s]\n' "${sec}" >> "${INI}"
  awk -v sec="[${sec}]" -v key="$key" -v val="$val" '
    function flush() { if (insec && !done) { print key "=" val; done=1 } }
    /^[[:space:]]*\[/ { flush(); insec = (index($0, sec) > 0) }
    insec && !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print key "=" val; done=1; next }
    { print }
    END { flush() }
  ' "${INI}" > "${INI}.tmp" && mv "${INI}.tmp" "${INI}"
}
set_ini "/Script/WDGame.WDGameSession"   ServerName     "${SERVER_NAME}"
set_ini "/Script/WDGame.WDGameSession"   ServerPassword "${SERVER_PASS}"
set_ini "/Script/Engine.GameSession"     MaxPlayers     "${MAX_PLAYERS}"
set_ini "/Script/WDRCON.WDRCONSettings"  bEnabled       "true"
set_ini "/Script/WDRCON.WDRCONSettings"  Port           "${RCON_LISTEN_PORT}"
set_ini "/Script/WDRCON.WDRCONSettings"  Password       "${WDRCON_PASSWORD}"
set_ini "/Script/WDRCON.WDRCONSettings"  BindAddress    "${RCON_BIND}"

[[ -f Configs/APIWhitelist.txt ]] || cat > Configs/APIWhitelist.txt <<'WL_EOF'
# WARDOGS Remote API IP whitelist
# One IP address or CIDR range per line. Lines starting with # are ignored.
# Leave empty to allow any IP.
WL_EOF

# ---------------------------------------------------------------------------
# Sanity checks on the game install
# ---------------------------------------------------------------------------
if [[ ! -x "Wardogs/Binaries/Linux/${BINARY}" ]]; then
  warn "Wardogs/Binaries/Linux/${BINARY} not found or not executable."
  warn "Either the Steam install failed (check the SteamCMD output above) or BINARY is wrong."
  ls -la Wardogs/Binaries/Linux/ 2>/dev/null || true
  exit 1
fi
chmod +x "Wardogs/Binaries/Linux/${BINARY}" 2>/dev/null

# ---------------------------------------------------------------------------
# Build the startup command (Pterodactyl {{VAR}} -> ${VAR})
# ---------------------------------------------------------------------------
MODIFIED_STARTUP=$(echo -e "$(echo -e "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")
eval "MODIFIED_STARTUP=\"${MODIFIED_STARTUP}\""
echo -e ":/home/container$ ${MODIFIED_STARTUP}"

# ---------------------------------------------------------------------------
# Background watchers
# ---------------------------------------------------------------------------
SERVER_PID=""
RELAUNCH_FLAG=/home/container/.relaunch_pending
request_restart() {   # $1 = reason
  local reason="$1"
  panel "${reason} - restarting server gracefully.."
  touch "${RELAUNCH_FLAG}"
  # watchers run as forked subshells, so signal by name rather than by a copied PID
  pkill -INT -f "Wardogs/Binaries/Linux/${BINARY}" 2>/dev/null
}

update_watcher() {
  [[ "${AUTO_UPDATE}" != "2" || -z "${SRCDS_APPID}" ]] && return
  steam "Auto Update Checks are Enabled, checking every ${UPDATE_CHECK_MINUTES} minutes.."
  while sleep "$((UPDATE_CHECK_MINUTES * 60))"; do
    local l r; l=$(local_buildid); r=$(remote_buildid)
    if [[ -n "${r}" && -n "${l}" && "${r}" != "${l}" ]]; then
      steam "New build available (${l} -> ${r}). Server restarts for update in ${WARN_TIMER} minutes."
      touch "${UPDATE_FLAG}"
      sleep "$((WARN_TIMER * 60))"
      request_restart "Update ready"
      return
    fi
  done
}

recycle_watcher() {
  [[ "${RECYCLE_HOURS}" == "0" ]] && return
  info "Server will restart for cleanup after ${RECYCLE_HOURS}h uptime."
  sleep "$((RECYCLE_HOURS * 3600))"
  request_restart "Recycle timer reached (${RECYCLE_HOURS}h)"
}

# ---------------------------------------------------------------------------
# Run loop: relaunch in-place after an update restart, otherwise exit with the
# server's code so the panel's crash detection behaves normally.
# ---------------------------------------------------------------------------
trap 'panel "Stop requested"; rm -f "${RELAUNCH_FLAG}"; [[ -n "${SERVER_PID}" ]] && kill -INT "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; exit 0' INT TERM

while :; do
  rm -f "${UPDATE_FLAG}" "${RELAUNCH_FLAG}"
  update_watcher  & UPD_PID=$!
  recycle_watcher & REC_PID=$!

  # Panel console (stdin) -> wardogs-console (RCON bridge) -> server stdin.
  # `bash -c exec` means $! is the game process itself.
  wardogs-console | bash -c "exec ${MODIFIED_STARTUP}" &
  SERVER_PID=$!
  wait "${SERVER_PID}" 2>/dev/null
  RC=$?
  kill "${UPD_PID}" "${REC_PID}" 2>/dev/null

  if [[ -f "${RELAUNCH_FLAG}" ]]; then
    [[ -f "${UPDATE_FLAG}" ]] && steam_update
    panel "Relaunching.."
    continue
  fi
  panel "Server exited with code ${RC}"
  exit "${RC}"
done
