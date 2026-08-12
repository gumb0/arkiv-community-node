#!/usr/bin/env bash
# status.sh — chain-level truth about this node. See usage() below.
set -euo pipefail
cd "$(dirname "$0")"

usage(){
  cat <<'EOF'
Usage: ./status.sh [--json]

Chain-level truth about this node, checked on demand. Answers what the
health badges cannot: am I on the right chain, am I current, does my view
match the official reference? Makes exactly two requests to the (metered)
official RPC per run; everything else is local.

  --json   one-line JSON instead of the report

Exit code: 0 = local node serving, right chain, and matching the reference
(or reference unreachable — a reference outage is not a local problem).
1 = something needs attention.
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
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null # .env does not exist on CI and linter would complain
  . ./.env
  set +a
fi
[ -n "$env_el_port" ] && EL_RPC_PORT="$env_el_port"
[ -n "$env_cl_port" ] && CL_HTTP_PORT="$env_cl_port"
EL="http://127.0.0.1:${EL_RPC_PORT:-8545}"
CL="http://127.0.0.1:${CL_HTTP_PORT:-5052}"

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

# ---- Official reference (metered: two requests, gently) -------------------
ref_state=unreachable ref_head='' hashes_match=''
if ref_hex=$(rpc "$OFFICIAL_RPC" eth_blockNumber | jfield result); then
  ref_state=reachable
  ref_head=$(hex2dec "$ref_hex")
  # Compare hashes at the highest height both sides have.
  cmp=$(( local_head < ref_head ? local_head : ref_head ))
  cmp_hex=$(printf '0x%x' "$cmp")
  ref_hash=$(rpc "$OFFICIAL_RPC" eth_getBlockByNumber "[\"$cmp_hex\",false]" | jfield hash || true)
  if [ "$cmp" = "$local_head" ]; then
    local_cmp_hash=$local_hash
  else
    local_cmp_hash=$(rpc "$EL" eth_getBlockByNumber "[\"$cmp_hex\",false]" | jfield hash)
  fi
  if [ -n "$ref_hash" ] && [ "$ref_hash" = "$local_cmp_hash" ]; then
    hashes_match=true
  else
    hashes_match=false
  fi
fi

# ---- Verdict ---------------------------------------------------------------
ok=true
[ "$chain_ok" = true ] || ok=false
[ "$hashes_match" = false ] && ok=false

if [ "$JSON" = 1 ]; then
  printf '{"ok":%s,"chain_id_ok":%s,"local_head":%s,"local_hash":"%s","head_age_seconds":%s,"el_peers":%s,"beacon":{"is_syncing":"%s","is_optimistic":"%s","el_offline":"%s","peers":"%s"},"reference":{"state":"%s","head":%s,"hashes_match":%s}}\n' \
    "$ok" "$chain_ok" "$local_head" "$local_hash" "$age" "$el_peers" \
    "$b_syncing" "$b_optimistic" "$b_el_offline" "$cl_peers" \
    "$ref_state" "${ref_head:-null}" "${hashes_match:-null}"
else
  # Color only on a terminal, and never when NO_COLOR is set.
  red='' green='' yellow='' reset=''
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
  fi
  printf 'chain id:   %s' "$(hex2dec "$chain_hex")"
  [ "$chain_ok" = true ] && printf ' (matches the network artifacts)\n' || printf ' — %sEXPECTED %s: wrong network!%s\n' "$red" "$CHAIN_ID" "$reset"
  printf 'local head: #%s %s (age %ss)\n' "$local_head" "$local_hash" "$age"
  printf 'execution:  peers %s\n' "$el_peers"
  printf 'beacon:     syncing=%s optimistic=%s el_offline=%s, peers %s\n' \
    "$b_syncing" "$b_optimistic" "$b_el_offline" "$cl_peers"
  case "$ref_state" in
    reachable)
      printf 'reference:  head #%s — ' "$ref_head"
      if [ "$hashes_match" = true ]; then printf 'hashes match at #%s\n' "$cmp"
      else printf '%sHASH MISMATCH at #%s — local %s vs reference %s%s\n' "$red" "$cmp" "$local_cmp_hash" "${ref_hash:-none}" "$reset"; fi
      if [ "$hashes_match" = true ] && [ "$age" -gt 60 ]; then
        printf '%snote:       in agreement with the reference, but the chain is quiet for %ss%s\n' "$yellow" "$age" "$reset"
      fi;;
    unreachable)
      printf '%sreference:  unreachable — local view only (not a local problem)%s\n' "$yellow" "$reset";;
  esac
  [ "$ok" = true ] && printf 'verdict:    %sOK%s\n' "$green" "$reset" || printf 'verdict:    %sNEEDS ATTENTION%s\n' "$red" "$reset"
fi
[ "$ok" = true ]
