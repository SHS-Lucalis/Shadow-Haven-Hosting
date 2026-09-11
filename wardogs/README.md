# WARDOGS – Docker image + Pterodactyl/Pelican egg (Shadow Haven Hosting)

Built from what the BisectHosting WARDOGS server (`games.bisecthosting.com/server/bfd5a25a`) actually runs.

## What Bisect runs (observed 2026-09-11)

| Item | Value |
|---|---|
| Game | WARDOGS (Bulkhead / Team17), Unreal Engine 5.7 Linux dedicated server, build `++Wardogs+Live-CL-499706` |
| Image | `docker.io/venturenodellc/wardogs:rconpatch` (not publicly listed) |
| Install | SteamCMD into `/home/container`, **logged-in Steam account** (not anonymous), beta branch **`community_provider_server`** |
| Startup | `./Wardogs/Binaries/Linux/<BINARY> -log -hostaddress=<IP> -hostport=<PORT> -port=<PORT> -RCONPort=<internal> -PatchId=<PRAGMA_BRANCH>_COMMUNITY_BISECT -StandaloneConfig="/home/container/Configs/ServerSettings.ini" -USERDIR="/home/container" -MaxServerWorkerThreads=6 -AllAntiCheat` |
| Hidden by the panel | binary name, Steam App ID, `-PatchId` value (Pragma backend branch), Steam credentials |
| Config | `Configs/ServerSettings.ini` (name, password, join gates, map rotation, RCON), `Configs/APIWhitelist.txt` (RCON IP allow-list) |
| RCON | HTTP API from the game, bound to `127.0.0.1:47990` by default; wrapper exposes it on game-port+1 for <https://rcon.wardogs.com> when "RCON Accessibility = Remote" |
| Ports | 5 allocations per server: game port, +1 RCON, +2..+4 spare |
| Resources | 32 GB RAM, 800% CPU (8 cores), 6 worker threads; nest recommends 24 GB |
| Boot-time output | Max players → Starbase setup → log dir → SteamCMD update check → server → "Loaded the whole level" |
| Extras | Auto-update watcher (hourly, warns then restarts), 12 h "recycle" restart deferred while a match is live |
| Disk after install | ~196 MB in `/home/container` (game payload lives in the SteamCMD-managed tree) |

## The blocker you need to clear first

The server package is **not publicly downloadable**. Bulkhead only ships it to approved
community providers through a Steam licence on the private `community_provider_server`
branch, plus a per-host Pragma `PatchId`. Until Shadow Haven is enrolled you will have:

* no Steam account that can `app_update` that branch,
* no App ID to point SteamCMD at,
* no `PRAGMA_BRANCH` value for `-PatchId`.

Apply via Bulkhead's community-provider program (BisectHosting announced theirs here:
<https://www.bisecthosting.com/blog/bisecthosting-bulkhead-partnership-wardogs-approved-hosting-partner-wardogs-server-preorders-available-now>).
Everything in this repo is parameterised so those three things are just egg variables.

## Files

```
Dockerfile           debian:bookworm-slim + steamcmd + UE5 runtime libs, runs as `container`
entrypoint.sh        boot wrapper (update, render ini, run loop, auto-update + recycle watchers)
wardogs-console.sh   panel console -> RCON HTTP bridge (players / raw rcon calls)
egg-wardogs.json     PTDL_v2 egg: install script, 19 variables, startup, done-string, stop signal
```

## Build & publish the image

```bash
docker build -t ghcr.io/shadowhaven/wardogs:latest .
docker push ghcr.io/shadowhaven/wardogs:latest
```

Change the image name in `egg-wardogs.json → docker_images` if you push somewhere else.

## Import the egg

Admin → Nests → create a "WARDOGS" nest → Import Egg → `egg-wardogs.json`.
Then fill the **provider-only** variables (they are hidden/non-editable for customers):

| Variable | Set to |
|---|---|
| `SRCDS_APPID` | dedicated-server App ID from Bulkhead |
| `SRCDS_BETAID` | `community_provider_server` (already default) |
| `SRCDS_BETAPASS` | only if Bulkhead gives you one |
| `STEAM_USER` / `STEAM_PASS` | the licensed Steam account (Steam Guard off, or use `STEAM_AUTH` once) |
| `BINARY` | the executable name in `Wardogs/Binaries/Linux/` (Bisect hides it; check the package) |
| `PRAGMA_BRANCH` | your Pragma branch → `-PatchId=<PRAGMA_BRANCH>_COMMUNITY_SHADOWHAVEN` |
| `HOST_TAG` | `SHADOWHAVEN` (Bisect's is `BISECT`) |

Customer-facing variables mirror Bisect's Startup tab: Server Name, Server Password,
Max Players (60–100), Auto Update (0/1/2), Restart Timer, RCON Accessibility, RCON
Password, RCON Port.

Give each server **at least 2 allocations** (game + RCON). Set the RCON Port variable
to the second allocation when a customer turns on remote RCON.

## How the wrapper behaves

1. Links `steamclient.so` into `~/.steam/sdk64` (Bisect's image is missing this – see the
   `SteamAPI_Init(): Failed to load module` line in their console).
2. `AUTO_UPDATE` ≠ 0 → `steamcmd +app_update <APPID> -beta community_provider_server`.
3. Renders only the panel-owned keys of `Configs/ServerSettings.ini` (`ServerName`,
   `ServerPassword`, `MaxPlayers`, RCON `bEnabled/Port/Password/BindAddress`); the customer's
   rotation, gates and balancing lines are left untouched. Keys/sections are added if missing.
4. Launches the egg's STARTUP; the panel's "done" string is `LevelLoad: Loaded the whole level`.
5. `AUTO_UPDATE=2` → every `UPDATE_CHECK_MINUTES` compares the branch build id with the local
   `appmanifest`; on change it waits `WARN_TIMER` minutes, SIGINTs the server, updates, relaunches
   in place (no crash event in the panel).
6. `RECYCLE_HOURS` → graceful restart after N hours (0 disables). Bisect defers this while a
   match is live; that needs the RCON match-state endpoint, which is not documented yet.
7. Stop signal is `^C` (SIGINT) so UE flushes its logs.

## Known gaps / things to confirm once you have the provider docs

* **RCON auth header** – the audit log shows an HTTP API (`GET /v1/players`) but not the auth
  scheme. `wardogs-console.sh` sends the password as both `Authorization: Bearer` and
  `X-RCON-Password`; trim to the right one.
* **Console commands** – Bisect's wrapper maps `reserve`, `rotation add/move/remove/save`,
  `scoretick`, etc. onto RCON routes. Add them to `wardogs-console.sh` as `case` entries once
  the routes are known.
* **Live-match deferral** for the recycle restart (see 6 above).
* **`-hostaddress`** uses `{{SERVER_IP}}`; if your Wings nodes allocate on `0.0.0.0`, swap it
  for a per-node public IP variable.
* **UE5 runtime libs** – the Dockerfile installs the usual set; if the binary reports a missing
  `.so`, add it to the `apt-get install` line.
