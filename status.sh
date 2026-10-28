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
is enabled, also checks that the tunnel is up. Once a provider key
exists, reads where the node stands with the load balancer through
./marketplace.sh status and shows it under "pool".

  --json   one-line JSON instead of the report

The verdict is SERVING (current, and the tunnel is connected for your
agreement), NOT SERVING YET (current; the line under it names the next
step towards the community pool), SYNCING (no fault, still catching up),
or NEEDS ATTENTION.

Exit code: 0 = both clients answering, right chain, and matching the
reference RPC (or reference unreachable — a reference outage is not a local
problem): SERVING, NOT SERVING YET or SYNCING. 1 = something needs
attention.
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

# ---- Pool, started first ----------------------------------------------------
# The marketplace records come from marketplace.sh status in its
# container, which takes seconds to start: it runs while the local
# checks and the reference requests go on, and is read once they are
# done. Nothing to read before a key exists.
pool_file='' pool_pid=''
if [ -f secrets/provider-key.json ]; then
  pool_file=$(mktemp)
  ./marketplace.sh status >"$pool_file" 2>&1 &
  pool_pid=$!
fi

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

# ---- Report, the node's part -----------------------------------------------
# Printed before the pool is waited for, so the wait is not a pause.
if [ "$JSON" != 1 ]; then
  # Color only on a terminal, and never when NO_COLOR is set.
  red='' green='' yellow='' reset=''
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
  fi
  # State glyphs in front of every judged line. Color alone does not
  # survive NO_COLOR, a pipe, or a colorblind reader; the glyph does.
  # Lines that only report (head, peers) and guidance under a judged line
  # keep the column blank. ASCII where the locale is not UTF-8.
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*) g_ok='✓' g_warn='!' g_fail='✗';;
    *)              g_ok='+' g_warn='!' g_fail='x';;
  esac

  if [ "$chain_ok" = true ]; then
    printf '%s chain id:   %s (matches the network artifacts)\n' "$g_ok" "$(hex2dec "$chain_hex")"
  else
    printf '%s%s chain id:   %s — EXPECTED %s: wrong network!%s\n' "$red" "$g_fail" "$(hex2dec "$chain_hex")" "$CHAIN_ID" "$reset"
    printf '              check NETWORK (or NETWORK_DIR) in .env; to switch networks:\n'
    printf '              ./setup.sh --wipe\n'
  fi
  printf '  local head: #%s %s (age %ss)\n' "$local_head" "$local_hash" "$age"
  # The manifest the first sync restored from, kept by the restore.
  if [ -f .setup-state/snapshot.json ]; then
    printf '  started:    from snapshot %s at block #%s\n' \
      "$(jfield run < .setup-state/snapshot.json)" "$(jfield block < .setup-state/snapshot.json)"
  fi
  printf '  execution:  peers %s\n' "$el_peers"
  if [ "$b_syncing" = unknown ]; then
    printf '%s%s beacon:     not answering at %s — is it running? (docker compose ps)%s\n' "$red" "$g_fail" "$CL" "$reset"
  elif [ "$cl_peers" = 0 ]; then
    printf '%s%s beacon:     syncing=%s optimistic=%s el_offline=%s, peers 0%s\n' \
      "$red" "$g_fail" "$b_syncing" "$b_optimistic" "$b_el_offline" "$reset"
    printf '  warning:    the beacon has no peers — new blocks cannot arrive\n'
    printf '              try: docker compose restart consensus\n'
    printf '              still 0 after a few minutes? the network endpoints may have\n'
    printf '              moved: ./setup.sh --refresh\n'
  else
    printf '%s beacon:     syncing=%s optimistic=%s el_offline=%s, peers %s\n' \
      "$g_ok" "$b_syncing" "$b_optimistic" "$b_el_offline" "$cl_peers"
  fi
  if [ "$restarting" = true ]; then
    printf '%s%s warning:    container restarts — execution %s, consensus %s%s\n' "$yellow" "$g_warn" "$el_restarts" "$cl_restarts" "$reset"
    printf '              a crash loop can look like a slow sync; if the count grows and\n'
    printf "              the logs show no error, check: dmesg | grep -i 'out of memory'\n"
  fi
  if [ "$tunnel_on" = 1 ]; then
    case "$tunnel_state" in
      running)      printf '%s tunnel:     connected, proxy running\n' "$g_ok";;
      disconnected) printf '%s%s tunnel:     not connected to the tunnel server%s\n' "$red" "$g_fail" "$reset"
                    printf '              the client log has the reason: docker compose logs --tail 5 tunnel\n';;
      unreachable)  printf '%s%s tunnel:     status endpoint not answering — is the tunnel service running? (docker compose ps)%s\n' "$red" "$g_fail" "$reset";;
      *)            printf '%s%s tunnel:     proxy %s%s%s\n' "$red" "$g_fail" "$tunnel_state" "${tunnel_err:+ — $tunnel_err}" "$reset";;
    esac
  fi
  case "$ref_state" in
    reachable)
      case "$hashes_match" in
        true)    printf '%s reference:  head #%s — hashes match at #%s\n' "$g_ok" "$ref_head" "$min";;
        false)   printf '%s%s reference:  head #%s — HASH MISMATCH at #%s — local %s vs reference %s%s\n' "$red" "$g_fail" "$ref_head" "$min" "$local_min_hash" "$ref_hash" "$reset"
                 printf '              a brief fork at the head can cause this — re-run to check\n'
                 printf '              if it persists, this node followed a different chain and must\n'
                 printf '              resync: ./setup.sh --refresh --wipe\n';;
        unknown) printf '%s%s reference:  head #%s — hash comparison unavailable (request failed)%s\n' "$yellow" "$g_warn" "$ref_head" "$reset";;
      esac
      if [ "$hashes_match" = true ]; then
        if [ "$ref_head" -gt "$local_head" ]; then
          printf '%s%s note:       behind the reference by %s blocks%s\n' "$yellow" "$g_warn" "$(( ref_head - local_head ))" "$reset"
        elif [ "$age" -gt 60 ]; then
          printf '%s%s note:       level with the reference, but the chain is quiet for %ss%s\n' "$yellow" "$g_warn" "$age" "$reset"
        fi
      fi;;
    unreachable)
      printf '%s%s reference:  unreachable — local view only (not a local problem)%s\n' "$yellow" "$g_warn" "$reset";;
  esac
fi

# ---- Pool ------------------------------------------------------------------
# Where this node stands with the load balancer: the marketplace records
# as one line of JSON (flat, a field per fact, null where there is
# nothing), from the run started first. Without a key the first step is
# the key.
pool_next=create-key pool_json='' pool_out=''
if [ -n "$pool_pid" ]; then
  # The object is the last line that is one: the container runtime may
  # print around it.
  wait "$pool_pid" && pool_json=$(grep '^{' "$pool_file" | tail -1 || true)
  pool_out=$(cat "$pool_file")
  rm -f "$pool_file"
  if [ -n "$pool_json" ]; then
    pool_next=$(printf '%s' "$pool_json" | jfield next || printf unknown)
  else
    pool_next=unknown
  fi
fi
pf(){ # pf <fact> — one of the pool's fields, "null" when it is not there
  local value
  value=$(printf '%s' "$pool_json" | jfield "$1" || true)
  printf '%s' "${value:-null}"
}
plural(){ [ "$1" = 1 ] || printf s; }
about(){ # about <seconds> — "about 3 hours": minutes, hours from two on, days from two on
  case "$1" in ''|*[!0-9]*) printf 'an unknown time'; return;; esac
  local m=$(( ($1 + 30) / 60 )) h
  if [ "$m" -lt 120 ]; then printf 'about %s minute%s' "$m" "$(plural "$m")"; return; fi
  h=$(( (m + 30) / 60 ))
  if [ "$h" -lt 48 ]; then printf 'about %s hours' "$h"; return; fi
  printf 'about %s days' "$(( (h + 12) / 24 ))"
}
in_words(){ case "$1" in 0|-*) printf now;; *) printf 'in %s' "$(about "$1")";; esac; }
ago_words(){ case "$1" in 0|-*) printf 'just now';; *) printf '%s ago' "$(about "$1")";; esac; }
# The pool's report, one line per fact, in the order of the steps.
pool_lines=()
if [ -n "$pool_json" ]; then
  if [ "$b_syncing" = true ]; then
    pool_lines+=("the node is still syncing: what follows is what it has seen so far")
  fi
  pool_lines+=("Key: $(pf address), $(pf balance_glm) GLM for gas on the Arkiv chain")
  if [ "$(pf listing_max_providers)" = null ]; then
    pool_lines+=("Load balancer: no listing on this chain")
  else
    pool_lines+=("Load balancer: pays $(pf listing_glm_per_request) GLM per request, $(pf listing_slots_taken) of $(pf listing_max_providers) slots taken")
  fi
  if [ "$(pf offer_key)" = null ]; then
    pool_lines+=("Offer: none")
  else
    pool_lines+=("Offer: $(pf offer_key), expires $(in_words "$(pf offer_expires_in_seconds)")")
  fi
  if [ "$(pf agreement_key)" = null ]; then
    pool_lines+=("Agreement: none")
  else
    pool_lines+=("Agreement: $(pf agreement_key), tunnel port $(pf agreement_port), $(pf agreement_glm_per_request) GLM per request, expires $(in_words "$(pf agreement_expires_in_seconds)")")
  fi
  case "$(pf tunnel_state)" in
    current) pool_lines+=("Tunnel: configured for this agreement");;
    other)   pool_lines+=("Tunnel: configured for agreement $(pf tunnel_agreement) on port $(pf tunnel_port), not for this one: run start-tunnel again");;
    ended)   pool_lines+=("Tunnel: configured for agreement $(pf tunnel_agreement) on port $(pf tunnel_port), which has ended: post a new offer, then run start-tunnel again");;
    *)       [ "$(pf agreement_key)" = null ] || pool_lines+=("Tunnel: not started yet: run start-tunnel");;
  esac
  # The load balancer opens the record at zero and writes the count into
  # it from time to time: before the first write there is no count yet.
  if [ "$(pf count)" = null ]; then
    pool_lines+=("Counting: no open record")
  elif [ "$(pf count_written_seconds_ago)" = null ]; then
    pool_lines+=("Counting: record opened $(ago_words "$(pf count_opened_seconds_ago)"), no count written yet (the load balancer writes it from time to time; since block $(pf count_opened_block), record $(pf count_record))")
  else
    pool_lines+=("Counting: $(pf count) requests as of the last write, $(ago_words "$(pf count_written_seconds_ago)") (since block $(pf count_opened_block), record $(pf count_record))")
  fi
  n=$(pf awaiting_records)
  if [ "$n" = 0 ]; then
    pool_lines+=("Awaiting payout: nothing")
  else
    pool_lines+=("Awaiting payout: $n closed record$(plural "$n"), $(pf awaiting_requests) requests")
  fi
  n=$(pf payouts_receipts)
  if [ "$n" = 0 ]; then
    pool_lines+=("Payouts: none yet")
  else
    pool_lines+=("Payouts: $n receipt$(plural "$n"), $(pf payouts_total_glm) GLM in total; last transfer $(pf payouts_last_tx) on chain $(pf payouts_last_chain_id)")
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
# Ready to serve current data: no fault, and the beacon node's own view,
# the same three flags as the consensus badge, says it is current.
ready=false
if [ "$ok" = true ] && [ "$b_syncing" = false ] && [ "$b_optimistic" = false ] && [ "$b_el_offline" = false ]; then
  ready=true
fi
# Serving: ready, the records say the tunnel is set up for the
# agreement, and the tunnel is connected. Otherwise the next step; a
# tunnel that is set up but down is a fault, caught above.
serving=false next=null
if [ "$ready" = true ]; then
  case "$pool_next" in
    null) if [ "$tunnel_state" = running ]; then serving=true; elif [ "$tunnel_on" = 0 ]; then next=start-tunnel; fi;;
    *)    next=$pool_next;;
  esac
fi

if [ "$JSON" = 1 ]; then
  next_json=null
  [ "$next" = null ] || next_json="\"$next\""
  # What the command printed, on one line, when it could not be read.
  pool_err_json=null
  if [ "$pool_next" = unknown ]; then
    pool_err_json="\"$(printf '%s' "$pool_out" | tr -s '[:space:]' ' ' | sed 's/ $//; s/[\\"]/\\&/g')\""
  fi
  printf '{"ok":%s,"ready":%s,"serving":%s,"next":%s,"chain_id_ok":%s,"local_head":%s,"local_hash":"%s","head_age_seconds":%s,"el_peers":%s,"beacon":{"is_syncing":"%s","is_optimistic":"%s","el_offline":"%s","peers":"%s"},"restarts":{"execution":%s,"consensus":%s},"tunnel":"%s","reference":{"state":"%s","head":%s,"hashes_match":"%s"},"pool":{"count":%s,"error":%s}}\n' \
    "$ok" "$ready" "$serving" "$next_json" "$chain_ok" "$local_head" "$local_hash" "$age" "$el_peers" \
    "$b_syncing" "$b_optimistic" "$b_el_offline" "$cl_peers" \
    "$el_restarts" "$cl_restarts" \
    "$tunnel_state" "$ref_state" "${ref_head:-null}" "$hashes_match" "$(pf count)" "$pool_err_json"
else
  if [ "$pool_next" = unknown ]; then
    # Everything the command printed, as it printed it.
    printf '%s%s pool:       marketplace status could not run:%s\n' "$yellow" "$g_warn" "$reset"
    while IFS= read -r line; do printf '              %s\n' "$line"; done <<<"$pool_out"
  else
    label='  pool:       '
    for line in "${pool_lines[@]}"; do
      printf '%s%s\n' "$label" "$line"
      label='              '
    done
  fi
  if [ "$ok" != true ]; then
    printf '%s%s overall:    NEEDS ATTENTION%s\n' "$red" "$g_fail" "$reset"
  elif [ "$serving" = true ]; then
    printf '%s%s overall:    SERVING%s\n' "$green" "$g_ok" "$reset"
  elif [ "$ready" = true ]; then
    printf '%s%s overall:    NOT SERVING YET%s\n' "$yellow" "$g_warn" "$reset"
    case "$next" in
      create-key)   printf '  next:       create your provider key: ./marketplace.sh create-key\n';;
      fund)         printf '  next:       get test GLM for your provider key %s\n' "$(pf address)"
                    printf '              at https://hub.arkiv.network/faucet, then ./marketplace.sh post-offer\n';;
      no-listing)   printf '  next:       the load balancer has no listing on this chain; nothing to do until it posts one\n';;
      post-offer)   printf '  next:       offer your node: ./marketplace.sh post-offer\n';;
      acceptance)   printf '  next:       waiting for the load balancer to accept your offer; then ./marketplace.sh start-tunnel\n';;
      start-tunnel) printf '  next:       connect the tunnel: ./marketplace.sh start-tunnel\n';;
      unknown)      printf '  next:       cannot tell: the marketplace records could not be read (pool above)\n';;
    esac
  else
    printf '%s%s overall:    SYNCING%s\n' "$yellow" "$g_warn" "$reset"
  fi
fi
[ "$ok" = true ]
