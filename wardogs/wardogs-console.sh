#!/bin/bash
# =============================================================================
#  wardogs-console - panel console -> WARDOGS RCON bridge
#
#  The UE5 server ignores stdin, so lines typed into the panel console are
#  forwarded to the server's HTTP RCON listener instead. WARDOGS' RCON is an
#  HTTP API (the audit log on a live server shows e.g. "GET /v1/players -> 200").
#
#  Built-in commands:
#    help                    this text
#    players                 GET /v1/players
#    rcon <METHOD> <path> [json-body]   raw call, e.g.  rcon GET /v1/server
#
#  Auth header: Bulkhead has not published the RCON auth contract. We send the
#  password as both a Bearer token and X-RCON-Password; adjust AUTH_HEADERS below
#  once you have the official RCON docs from the community-provider program.
# =============================================================================
RCON_URL="http://127.0.0.1:${RCON_LISTEN_PORT:-47990}"
AUTH_HEADERS=(-H "Authorization: Bearer ${WDRCON_PASSWORD}" -H "X-RCON-Password: ${WDRCON_PASSWORD}")

rcon_call() {
  local method="$1" path="$2" body="${3:-}"
  local out
  if [[ -n "${body}" ]]; then
    out=$(curl -sS -m 10 -X "${method}" "${AUTH_HEADERS[@]}" -H 'Content-Type: application/json' -d "${body}" "${RCON_URL}${path}" -w '\n[http %{http_code}]')
  else
    out=$(curl -sS -m 10 -X "${method}" "${AUTH_HEADERS[@]}" "${RCON_URL}${path}" -w '\n[http %{http_code}]')
  fi
  # pretty-print JSON when it is JSON
  if echo "${out}" | head -n -1 | jq -e . >/dev/null 2>&1; then
    echo "${out}" | head -n -1 | jq .
    echo "${out}" | tail -n 1
  else
    echo "${out}"
  fi
}

while IFS= read -r line; do
  set -- ${line}
  case "${1,,}" in
    ""|"#"*) ;;
    help)
      echo -e "\033[0;32m[RCON]:\033[0m console commands: help | players | rcon <METHOD> <path> [json]"
      echo -e "\033[0;32m[RCON]:\033[0m full admin tooling: https://rcon.wardogs.com (set RCON Accessibility to Remote)"
      ;;
    players) rcon_call GET /v1/players ;;
    rcon)    shift; rcon_call "${1:-GET}" "${2:-/}" "${*:3}" ;;
    *)       echo -e "\033[1;31m[Warn]:\033[0m unknown console command '${1}'. Type 'help'." ;;
  esac
done
