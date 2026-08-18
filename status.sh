#!/usr/bin/env bash
# status.sh — chain-level truth about this node. See usage() below.
set -euo pipefail
cd "$(dirname "$0")"

usage(){
  cat <<'EOF'
Usage: ./status.sh [--json]

Chain-level truth about this node, checked on demand. Answers what the
health badges cannot: am I on the right chain, am I current, does my view
match the official reference? Makes at most two requests to the (metered)
official RPC per run; everything else is local. When the tunnel profile
is enabled, also checks that the tunnel is up.

  --json   one-line JSON instead of the report

Exit code: 0 = both clients answering, right chain, and matching the
reference RPC (or reference unreachable — a reference outage is not a local
problem). 1 = something needs attention.
EOF
}

JSON=0
case "${1:-}" in
  "")       ;;
  --json)   JSON=1;;
  -h|--help) usage; exit 0;;
  *) usage >&2; printf 'status.sh: unexpected argument: %s\n' "$1" >&2; exit 2;;
esac

# Operator ports from .env file (environment variables win, same rule as setup.sh).
env_el_port="${EL_RPC_PORT:-}"
env_cl_port="${CL_HTTP_PORT:-}"
env_profiles="${COMPOSE_PROFILES:-}"
env_tunnel_status_port="${TUNNEL_STATUS_PORT:-}"
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null # .env does not exist on CI and linter would complain
  . ./.env
  set +a
fi
[ -n "$env_el_port" ] && EL_RPC_PORT="$env_el_port"
[ -n "$env_cl_port" ] && CL_HTTP_PORT="$env_cl_port"
[ -n "$env_profiles" ] && COMPOSE_PROFILES="$env_profiles"
[ -n "$env_tunnel_status_port" ] && TUNNEL_STATUS_PORT="$env_tunnel_status_port"
EL="http://127.0.0.1:${EL_RPC_PORT:-8545}"
CL="http://127.0.0.1:${CL_HTTP_PORT:-5052}"
tunnel_on=0
case ",${COMPOSE_PROFILES:-}," in *,tunnel,*) tunnel_on=1;; esac

# Network identity, written by setup.sh.
[ -f .setup-state/artifacts.env ] || { printf 'status.sh: no .setup-state/artifacts.env — run ./setup.sh first\n' >&2; exit 1; }
# shellcheck source=/dev/null # artifacts.env does not exist on CI and linter would complain
. .setup-state/artifacts.env   # OFFICIAL_RPC, CHAIN_ID

rpc(){ # rpc <url> <method> [params-json]
  curl -sf -m 5 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":${3:-[]}}" "$1"
}
jfield(){ # jfield <name>  — first string/bool value of "name" on stdin
  tr -d '\n\r' | grep -o "\"$1\": *\"\?[^\",}]*" | head -1 | sed 's/.*: *"\?//'
}
hex2dec(){ printf '%d' "$((16#${1#0x}))"; }

# ---- Local EL node -----------------------------------------------------------
if ! head_json=$(rpc "$EL" eth_getBlockByNumber '["latest",false]'); then
  printf 'local RPC not answering at %s — is the node running? (docker compose ps)\n' "$EL" >&2
  exit 1
fi
local_hex=$(printf '%s' "$head_json" | jfield number)
local_hash=$(printf '%s' "$head_json" | jfield hash)
local_ts=$(printf '%s' "$head_json" | jfield timestamp)
local_head=$(hex2dec "$local_hex")
age=$(( $(date +%s) - $(hex2dec "$local_ts") ))

chain_hex=$(rpc "$EL" eth_chainId | jfield result)
chain_ok=false
[ "$(hex2dec "$chain_hex")" = "$CHAIN_ID" ] && chain_ok=true

peers_hex=$(rpc "$EL" net_peerCount | jfield result || printf '0x0')
el_peers=$(hex2dec "$peers_hex")

# ---- Local CL node ----------------------------------------------------------
if beacon_json=$(curl -sf -m 5 "$CL/eth/v1/node/syncing"); then
  b_syncing=$(printf '%s' "$beacon_json" | jfield is_syncing)
  b_optimistic=$(printf '%s' "$beacon_json" | jfield is_optimistic)
  b_el_offline=$(printf '%s' "$beacon_json" | jfield el_offline)
else
  b_syncing=unknown b_optimistic=unknown b_el_offline=unknown
fi
cl_peers=$(curl -sf -m 5 "$CL/eth/v1/node/peer_count" | jfield connected || printf 'unknown')

# ---- Restart counts ---------------------------------------------------------
# A crash loop hides well: the container is freshly "Up" and the badges
# recover between deaths — and a kernel OOM kill leaves no error in the
# client's own log. The count plus a recent last start is the signature;
# a nonzero count with a long-running container is old news, not warned
# about. The daemon resets the count on reboot.
container_life(){ # container_life <service> — "restart-count seconds-since-last-start"
  local info count started
  if info=$(docker inspect --format '{{.RestartCount}} {{.State.StartedAt}}' \
              "$(docker compose ps -q "$1")" 2>/dev/null); then
    read -r count started <<<"$info"
    printf '%s %s' "$count" "$(( $(date +%s) - $(date -d "$started" +%s) ))"
  else
    printf '0 -1'
  fi
}
read -r el_restarts el_started_ago <<<"$(container_life execution)"
read -r cl_restarts cl_started_ago <<<"$(container_life consensus)"
restarting=false
{ [ "$el_restarts" != 0 ] && [ "$el_started_ago" -ge 0 ] && [ "$el_started_ago" -lt 3600 ]; } && restarting=true
{ [ "$cl_restarts" != 0 ] && [ "$cl_started_ago" -ge 0 ] && [ "$cl_started_ago" -lt 3600 ]; } && restarting=true

# ---- Tunnel client (only when the tunnel profile is enabled) ----------------
tunnel_state=off tunnel_err=''
if [ "$tunnel_on" = 1 ]; then
  if tunnel_json=$(curl -sf -m 5 "http://127.0.0.1:${TUNNEL_STATUS_PORT:-7400}/api/status"); then
    # While not connected the endpoint answers with {} — no status field at
    # all, so the extraction must survive finding nothing.
    tunnel_state=$(printf '%s' "$tunnel_json" | jfield status || true)
    [ -n "$tunnel_state" ] || tunnel_state=disconnected
    tunnel_err=$(printf '%s' "$tunnel_json" | jfield err || true)
  else
    tunnel_state=unreachable
  fi
fi

# ---- Official RPC reference -------------------------------------------------
# One metered request in the common case: the reference's head block carries
# its number and hash together. A second is needed only while this node is
# behind, to ask for their hash at our height.
ref_state=unreachable ref_head='' hashes_match=unknown
if ref_json=$(rpc "$OFFICIAL_RPC" eth_getBlockByNumber '["latest",false]'); then
  ref_state=reachable
  ref_head=$(hex2dec "$(printf '%s' "$ref_json" | jfield number)")
  # Compare at the highest height both sides have.
  min=$(( local_head < ref_head ? local_head : ref_head ))
  min_hex=$(printf '0x%x' "$min")
  if [ "$min" = "$ref_head" ]; then
    ref_hash=$(printf '%s' "$ref_json" | jfield hash)
  else
    ref_hash=$(rpc "$OFFICIAL_RPC" eth_getBlockByNumber "[\"$min_hex\",false]" | jfield hash || true)
  fi
  if [ "$min" = "$local_head" ]; then
    local_min_hash=$local_hash
  else
    local_min_hash=$(rpc "$EL" eth_getBlockByNumber "[\"$min_hex\",false]" | jfield hash)
  fi
  # No reference hash means the comparison could not be made — not a
  # mismatch. A reference problem is never this node's fault.
  if [ -z "$ref_hash" ]; then
    hashes_match=unknown
  elif [ "$ref_hash" = "$local_min_hash" ]; then
    hashes_match=true
  else
    hashes_match=false
  fi
fi

# ---- Verdict ---------------------------------------------------------------
# Local faults fail the verdict; a reference problem never does. Syncing
# and optimistic are normal transient states, reported but not faults.
ok=true
[ "$chain_ok" = true ] || ok=false
[ "$hashes_match" = false ] && ok=false
[ "$b_syncing" = unknown ] && ok=false      # the beacon node is not answering
[ "$b_el_offline" = true ] && ok=false      # the two clients are not talking
[ "$cl_peers" = 0 ] && ok=false             # no peers: new blocks cannot arrive
                                            # ("unknown" is not a fault — only a
                                            # confirmed zero is)
if [ "$tunnel_state" != off ] && [ "$tunnel_state" != running ]; then
  ok=false
fi

if [ "$JSON" = 1 ]; then
  printf '{"ok":%s,"chain_id_ok":%s,"local_head":%s,"local_hash":"%s","head_age_seconds":%s,"el_peers":%s,"beacon":{"is_syncing":"%s","is_optimistic":"%s","el_offline":"%s","peers":"%s"},"restarts":{"execution":%s,"consensus":%s},"tunnel":"%s","reference":{"state":"%s","head":%s,"hashes_match":"%s"}}\n' \
    "$ok" "$chain_ok" "$local_head" "$local_hash" "$age" "$el_peers" \
    "$b_syncing" "$b_optimistic" "$b_el_offline" "$cl_peers" \
    "$el_restarts" "$cl_restarts" \
    "$tunnel_state" "$ref_state" "${ref_head:-null}" "$hashes_match"
else
  # Color only on a terminal, and never when NO_COLOR is set.
  red='' green='' yellow='' reset=''
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
  fi
  printf 'chain id:   %s' "$(hex2dec "$chain_hex")"
  if [ "$chain_ok" = true ]; then
    printf ' (matches the network artifacts)\n'
  else
    printf ' — %sEXPECTED %s: wrong network!%s\n' "$red" "$CHAIN_ID" "$reset"
    printf '            check NETWORK_DIR in .env; to switch networks:\n'
    printf '            docker compose down -v && ./setup.sh\n'
  fi
  printf 'local head: #%s %s (age %ss)\n' "$local_head" "$local_hash" "$age"
  printf 'execution:  peers %s\n' "$el_peers"
  if [ "$b_syncing" = unknown ]; then
    printf '%sbeacon:     not answering at %s — is it running? (docker compose ps)%s\n' "$red" "$CL" "$reset"
  else
    printf 'beacon:     syncing=%s optimistic=%s el_offline=%s, peers %s\n' \
      "$b_syncing" "$b_optimistic" "$b_el_offline" "$cl_peers"
    if [ "$cl_peers" = 0 ]; then
      printf '%swarning:    the beacon has no peers — new blocks cannot arrive%s\n' "$red" "$reset"
      printf '            try: docker compose restart consensus\n'
      printf '            still 0 after a few minutes? the network endpoints may have\n'
      printf '            moved: ./setup.sh --refresh\n'
    fi
  fi
  if [ "$restarting" = true ]; then
    printf '%swarning:    container restarts — execution %s, consensus %s%s\n' "$yellow" "$el_restarts" "$cl_restarts" "$reset"
    printf '            a crash loop can look like a slow sync; if the count grows and\n'
    printf "            the logs show no error, check: dmesg | grep -i 'out of memory'\n"
  fi
  if [ "$tunnel_on" = 1 ]; then
    case "$tunnel_state" in
      running)      printf 'tunnel:     connected, proxy running\n';;
      disconnected) printf '%stunnel:     not connected to the tunnel server%s\n' "$red" "$reset"
                    printf '            the client log has the reason: docker compose logs --tail 5 tunnel\n';;
      unreachable)  printf '%stunnel:     status endpoint not answering — is the tunnel service running? (docker compose ps)%s\n' "$red" "$reset";;
      *)            printf '%stunnel:     proxy %s%s%s\n' "$red" "$tunnel_state" "${tunnel_err:+ — $tunnel_err}" "$reset";;
    esac
  fi
  case "$ref_state" in
    reachable)
      printf 'reference:  head #%s — ' "$ref_head"
      case "$hashes_match" in
        true)    printf 'hashes match at #%s\n' "$min";;
        false)   printf '%sHASH MISMATCH at #%s — local %s vs reference %s%s\n' "$red" "$min" "$local_min_hash" "$ref_hash" "$reset"
                 printf '            a brief fork at the head can cause this — re-run to check\n'
                 printf '            if it persists, this node followed a different chain and must\n'
                 printf '            resync: docker compose down -v && ./setup.sh --refresh\n';;
        unknown) printf '%shash comparison unavailable (request failed)%s\n' "$yellow" "$reset";;
      esac
      if [ "$hashes_match" = true ]; then
        if [ "$ref_head" -gt "$local_head" ]; then
          printf '%snote:       behind the reference by %s blocks%s\n' "$yellow" "$(( ref_head - local_head ))" "$reset"
        elif [ "$age" -gt 60 ]; then
          printf '%snote:       level with the reference, but the chain is quiet for %ss%s\n' "$yellow" "$age" "$reset"
        fi
      fi;;
    unreachable)
      printf '%sreference:  unreachable — local view only (not a local problem)%s\n' "$yellow" "$reset";;
  esac
  [ "$ok" = true ] && printf '%soverall:    OK%s\n' "$green" "$reset" || printf '%soverall:    NEEDS ATTENTION%s\n' "$red" "$reset"
fi
[ "$ok" = true ]
