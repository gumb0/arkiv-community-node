#!/usr/bin/env bash
# The CI gate, runnable locally: exactly what .github/workflows/ci.yml runs.
set -euo pipefail
cd "$(dirname "$0")/.."

note(){ printf '== %s\n' "$*"; }

note "shellcheck every shell script"
git ls-files '*.sh' | xargs -r shellcheck

note "marketplace package: typecheck and unit tests"
(cd marketplace && npm ci --silent && npm run --silent typecheck && npm test)

note "preflight reports every check, and names the commands a machine lacks"
# The verdict depends on the runner (its disk is well below the floor),
# so the run is judged by its lines, not its exit code; the failing path
# is driven by a PATH with the basic tools and none of the five commands.
out=$(./preflight.sh || true)
for label in architecture commands docker memory disk clock ports; do
  printf '%s\n' "$out" | grep -q "^. $label:" || { echo "preflight has no $label line:"; printf '%s\n' "$out"; exit 1; } >&2
done
# A directory with every command of /usr/bin except the named ones, to
# stand as the PATH of a machine that lacks them.
path_without(){
  local dir f
  dir=$(mktemp -d)
  for f in /usr/bin/*; do
    case " $* " in *" ${f##*/} "*) continue;; esac
    ln -s "$f" "$dir/" 2>/dev/null || true
  done
  printf '%s\n' "$dir"
}
bare=$(path_without docker git openssl envsubst curl)
if out=$(PATH=$bare ./preflight.sh); then echo "preflight passed with no docker on the PATH" >&2; exit 1; fi
for command in docker git openssl envsubst curl; do
  printf '%s\n' "$out" | grep -q "$command is not installed" || { echo "preflight did not name $command"; exit 1; } >&2
done
rm -rf "$bare"

note "setup.sh runs the preflight on its first run only, and stops on a failure"
# A copy of the two scripts with no state directory is a first run: the
# preflight runs, fails on the missing git, and setup stops before the
# registry clone. With a state directory it is a later run: setup goes
# straight on and fails at its own clone step with its own message.
tmp=$(mktemp -d)
cp setup.sh preflight.sh "$tmp/"
nogit=$(path_without git)
if out=$(cd "$tmp" && NETWORK=one PATH=$nogit ./setup.sh 2>&1); then echo "a first run with no git went on" >&2; exit 1; fi
printf '%s\n' "$out" | grep -q 'git is not installed' || { echo "the first run did not run the preflight:"; printf '%s\n' "$out"; exit 1; } >&2
printf '%s\n' "$out" | grep -q 'does not fit a node' || { echo "the first run did not stop on the preflight:"; printf '%s\n' "$out"; exit 1; } >&2
[ ! -d "$tmp/db-chain-networks" ] || { echo "setup cloned the registry before the preflight" >&2; exit 1; }
mkdir "$tmp/.setup-state"
if out=$(cd "$tmp" && NETWORK=one PATH=$nogit ./setup.sh 2>&1); then echo "a later run with no git went on" >&2; exit 1; fi
printf '%s\n' "$out" | grep -q 'setup.sh: git is not installed' || { echo "the later run did not fail at its own clone step:"; printf '%s\n' "$out"; exit 1; } >&2
if printf '%s\n' "$out" | grep -q 'does not fit a node'; then echo "a later run ran the preflight" >&2; exit 1; fi
rm -rf "$tmp" "$nogit"

note "render through setup.sh against the fixture network"
NETWORK_DIR=tests/fixture-network ./setup.sh --render-only

note "the network is found in the registry by name"
# A registry tree of the fixture stands in for the clone at its place,
# with a real clone and .env moved aside so the name alone decides; a
# name the registry lacks or doubles is refused.
tmp=$(mktemp -d)
[ -d db-chain-networks ] && mv db-chain-networks "$tmp/registry.kept"
[ -f .env ] && mv .env "$tmp/env.kept"
trap '[ -d "$tmp/registry.kept" ] && mv "$tmp/registry.kept" db-chain-networks; [ -f "$tmp/env.kept" ] && mv "$tmp/env.kept" .env; rm -rf "$tmp"' EXIT
mkdir -p db-chain-networks/networks/testnet db-chain-networks/networks/devnet
cp -a tests/fixture-network db-chain-networks/networks/testnet/one
NETWORK=one ./setup.sh --render-only >/dev/null
if NETWORK=zzz ./setup.sh --render-only 2>/dev/null; then echo "an unknown network name rendered" >&2; exit 1; fi
cp -a tests/fixture-network db-chain-networks/networks/devnet/one
if NETWORK=one ./setup.sh --render-only 2>/dev/null; then echo "a doubled network name rendered" >&2; exit 1; fi
rm -rf db-chain-networks
[ -d "$tmp/registry.kept" ] && mv "$tmp/registry.kept" db-chain-networks
[ -f "$tmp/env.kept" ] && mv "$tmp/env.kept" .env
rm -rf "$tmp"
trap - EXIT

note "a metadata value that is not a number or a DNS name is refused"
# The values are written into a file status.sh sources, so the refusal
# has to name the field, and nothing is rendered from such a network.
tmp=$(mktemp -d)
refused(){ # field, bad line
  cp -a tests/fixture-network "$tmp/bad"
  sed -i "s/^$1:.*/$2/" "$tmp/bad/metadata.yaml"
  # The checksums are verified first; the bad value has to pass them.
  (cd "$tmp/bad" && sha256sum metadata.yaml > SHA256SUMS)
  if NETWORK_DIR=$tmp/bad ./setup.sh --render-only 2>"$tmp/err"; then echo "a bad $1 rendered" >&2; exit 1; fi
  grep -q "$1" "$tmp/err"
  rm -rf "$tmp/bad"
}
# shellcheck disable=SC2016  # The shell syntax is the bad value itself, not meant to expand.
refused baseDomain 'baseDomain: example.org;$(touch pwned)'
# shellcheck disable=SC2016
refused name 'name: fixture`id`'
refused chainId 'chainId: 0x1'
rm -rf "$tmp"

note "validate the merged stack"
docker compose config -q

note "the upstream drift check tells a changed script from a changed network"
# Two scripts that differ in the per-network lines alone hash the same;
# one changed line of the body is drift. Over a record of its own, so
# the real one is neither read nor touched.
tmp=$(mktemp -d)
printf '%s\n' '#!/usr/bin/env bash' '# run-node.sh — bring up a node that follows the one chain.' 'NETWORK=one' 'EL_IMAGE=el:1' 'CL_IMAGE=cl:1' 'SNAPSHOTS_URL=https://one' 'docker run el' > "$tmp/one.sh"
printf '%s\n' '#!/usr/bin/env bash' '# run-node.sh — bring up a node that follows the two chain.' 'NETWORK=two' 'EL_IMAGE=el:2' 'CL_IMAGE=cl:2' 'SNAPSHOTS_URL=https://two' 'docker run el' > "$tmp/two.sh"
sed 's/docker run el/docker run el --flag/' "$tmp/one.sh" > "$tmp/changed.sh"
DRIFT_RECORD=$tmp/record tests/upstream-drift.sh --record "$tmp/one.sh" abc1234 >/dev/null
DRIFT_RECORD=$tmp/record tests/upstream-drift.sh "$tmp/two.sh" >/dev/null
if DRIFT_RECORD=$tmp/record tests/upstream-drift.sh "$tmp/changed.sh" 2>/dev/null; then echo "a changed upstream script passed the drift check" >&2; exit 1; fi
rm -rf "$tmp"

note "the snapshot restore, over a fixture served from this host"
tests/snapshot-restore.sh

note "a changed genesis, or a changed genesis time, is a re-genesis"
# Over a state directory of its own, so a checkout's real records are
# neither read nor touched.
state_bak=$(mktemp -d)
[ -d .setup-state ] && mv .setup-state "$state_bak/kept"
mkdir .setup-state
printf '%s\n' 0000000000000000000000000000000000000000000000000000000000000000 > .setup-state/genesis.sha256
NETWORK_DIR=tests/fixture-network ./setup.sh --render-only | grep "genesis has changed" >/dev/null
rm .setup-state/genesis.sha256
printf '%s\n' 1600000000 > .setup-state/genesis-time
NETWORK_DIR=tests/fixture-network ./setup.sh --render-only | grep "genesis time has changed" >/dev/null
rm -rf .setup-state
[ -d "$state_bak/kept" ] && mv "$state_bak/kept" .setup-state
rm -rf "$state_bak"

note "rendered output carries the fixture values"
grep -q 'fixture-el:ci' compose.override.yaml
grep -q 'fixture-cl:ci' compose.override.yaml
grep -q '192.0.2.10:30000,enode://' compose.override.yaml
grep -q 'enr:-fixture-aaaa,enr:-fixture-bbbb' compose.override.yaml

note "tunnel render carries the agreement values"
NETWORK_DIR=tests/fixture-network COMPOSE_PROFILES=tunnel \
  TUNNEL_SERVER_ADDR=203.0.113.7 TUNNEL_SERVER_PORT=7000 TUNNEL_REMOTE_PORT=18545 \
  TUNNEL_AGREEMENT=0x01 TUNNEL_TOKEN=0xdeadbeef \
  ./setup.sh --render-only
grep -q 'serverAddr = "203.0.113.7"' frpc.toml
grep -q 'serverPort = 7000' frpc.toml
grep -q 'remotePort = 18545' frpc.toml
grep -q 'metadatas.agreement = "0x01"' frpc.toml
grep -q 'metadatas.token = "0xdeadbeef"' frpc.toml

note "the rendered tunnel config is readable by its owner alone"
# It holds the admission token. A loose umask, and a file left behind by
# an earlier render with loose permissions, must both end at 0600.
chmod 664 frpc.toml
(
  umask 0002
  NETWORK_DIR=tests/fixture-network COMPOSE_PROFILES=tunnel \
    TUNNEL_SERVER_ADDR=203.0.113.7 TUNNEL_SERVER_PORT=7000 TUNNEL_REMOTE_PORT=18545 \
    TUNNEL_AGREEMENT=0x01 TUNNEL_TOKEN=0xdeadbeef \
    ./setup.sh --render-only
)
[ "$(stat -c %a frpc.toml)" = 600 ] || { echo "frpc.toml is $(stat -c %a frpc.toml), not 600" >&2; exit 1; }
rm frpc.toml
(
  umask 0002
  NETWORK_DIR=tests/fixture-network COMPOSE_PROFILES=tunnel \
    TUNNEL_SERVER_ADDR=203.0.113.7 TUNNEL_SERVER_PORT=7000 TUNNEL_REMOTE_PORT=18545 \
    TUNNEL_AGREEMENT=0x01 TUNNEL_TOKEN=0xdeadbeef \
    ./setup.sh --render-only
)
[ "$(stat -c %a frpc.toml)" = 600 ] || { echo "a new frpc.toml is $(stat -c %a frpc.toml), not 600" >&2; exit 1; }

note "marketplace.sh merges the tunnel settings into .env"
tmp=$(mktemp -d)
printf '%s\n' 'NETWORK_DIR=/nets/x' '#TUNNEL_REMOTE_PORT=' 'TUNNEL_TOKEN=old' > "$tmp/.env"
printf '%s\n' 'TUNNEL_SERVER_ADDR=203.0.113.7' 'TUNNEL_REMOTE_PORT=18545' 'TUNNEL_TOKEN=new' > "$tmp/tunnel.env"
# shellcheck source=marketplace.sh
. ./marketplace.sh
merge_env "$tmp/.env" "$tmp/tunnel.env"
enable_profile "$tmp/.env" tunnel
grep -qx 'NETWORK_DIR=/nets/x' "$tmp/.env"            # untouched
grep -qx '#TUNNEL_REMOTE_PORT=' "$tmp/.env"           # a comment stays a comment
grep -qx 'TUNNEL_REMOTE_PORT=18545' "$tmp/.env"       # and the value is added
grep -qx 'TUNNEL_TOKEN=new' "$tmp/.env"               # a set line is replaced
grep -qx 'TUNNEL_SERVER_ADDR=203.0.113.7' "$tmp/.env" # a missing line is added
grep -qx 'COMPOSE_PROFILES=tunnel' "$tmp/.env"        # a missing profile line is added
enable_profile "$tmp/.env" monitor
grep -qx 'COMPOSE_PROFILES=tunnel,monitor' "$tmp/.env" # added to a set one
enable_profile "$tmp/.env" tunnel
grep -qx 'COMPOSE_PROFILES=tunnel,monitor' "$tmp/.env" # not added twice
[ "$(grep -c '^TUNNEL_TOKEN=' "$tmp/.env")" = 1 ]      # replaced, not added again
# A trailing comment or a trailing space on the profile line, as an
# operator's editor leaves them, is no part of the value.
printf '%s\n' 'COMPOSE_PROFILES=monitor #,tunnel' > "$tmp/.env"
enable_profile "$tmp/.env" tunnel
grep -qx 'COMPOSE_PROFILES=monitor,tunnel' "$tmp/.env"
printf '%s\n' 'COMPOSE_PROFILES=monitor ' > "$tmp/.env"
enable_profile "$tmp/.env" tunnel
grep -qx 'COMPOSE_PROFILES=monitor,tunnel' "$tmp/.env"
rm -rf "$tmp"

note "status.sh tells a syncing node from a ready one"
# status.sh in a directory of its own, over two fake nodes: this node on
# one port (execution and beacon), the reference on another.
tmp=$(mktemp -d)
cp status.sh "$tmp/"
mkdir "$tmp/.setup-state"
printf 'OFFICIAL_RPC=http://127.0.0.1:18602\nCHAIN_ID=999999\n' > "$tmp/.setup-state/artifacts.env"
python3 tests/fake-node.py 18602 1000 >/dev/null 2>&1 & reference=$!
python3 tests/fake-node.py 18601 100 syncing >/dev/null 2>&1 & local_node=$!
# A failed check exits the script; the fakes must not outlive it.
trap 'kill "$reference" "$local_node" 2>/dev/null || true' EXIT
sleep 1
# The tunnel profile is off unless a case turns it on with PROFILES;
# the caller's own COMPOSE_PROFILES does not reach the script.
status(){ EL_RPC_PORT=18601 CL_HTTP_PORT=18601 COMPOSE_PROFILES="${PROFILES:-}" NO_COLOR=1 "$tmp/status.sh" "$@"; }
# A healthy sync is no fault, so the exit code is 0, but it is not ready.
status --json | grep -q '"ok":true'
status --json | grep -q '"ready":false'
status > "$tmp/out"
grep -q 'overall: *SYNCING' "$tmp/out"
grep -q 'behind the reference by 900 blocks' "$tmp/out"
kill "$local_node"; wait "$local_node" 2>/dev/null || true
python3 tests/fake-node.py 18601 1000 >/dev/null 2>&1 & local_node=$!
sleep 1
status --json | grep -q '"ready":true'
# Synced without a key: the next step is the key.
status --json | grep -q '"serving":false,"next":"create-key"'
status > "$tmp/out"
grep -q 'overall: *NOT SERVING YET' "$tmp/out"
grep -q 'next: *create your provider key' "$tmp/out"
# With a key, the records come from marketplace.sh status as JSON: a
# stand-in for the wrapper answers from an environment variable, and
# the script renders the report from the fields.
mkdir "$tmp/secrets" && : > "$tmp/secrets/provider-key.json"
cat > "$tmp/marketplace.sh" <<'STANDIN'
#!/usr/bin/env bash
[ -n "$MARKETPLACE_STATUS" ] || { printf '%s\n' "your node is not answering: is it running? (docker compose ps)" "  fetch failed" >&2; exit 1; }
printf '%s\n' "$MARKETPLACE_STATUS"
STANDIN
chmod +x "$tmp/marketplace.sh"
pool='{"address":"0x2121","balance_glm":"0","listing_glm_per_request":null,"listing_slots_taken":null,"listing_max_providers":null,"offer_key":null,"agreement_key":null,"tunnel_state":"unconfigured","count":null,"awaiting_records":0,"payouts_receipts":0,"next":"fund"}'
MARKETPLACE_STATUS=$pool status > "$tmp/out"
grep -q 'pool: *Key: 0x2121, 0 GLM for gas' "$tmp/out"
grep -q '^ *Load balancer: no listing' "$tmp/out"
grep -q '^ *Offer: none' "$tmp/out"
grep -q '^ *Agreement: none' "$tmp/out"
grep -q '^ *Counting: no open record' "$tmp/out"
grep -q '^ *Payouts: none yet' "$tmp/out"
grep -q 'next: *get test GLM for your provider key 0x2121' "$tmp/out"
MARKETPLACE_STATUS=$pool status --json | grep -q '"next":"fund"'
MARKETPLACE_STATUS=${pool//\"next\":\"fund\"/\"next\":\"no-listing\"} status | grep -q 'next: *the load balancer has no listing'
# Set up for the agreement and the tunnel connected: serving.
pool='{"address":"0x2121","balance_glm":"1","listing_glm_per_request":"0.001","listing_slots_taken":7,"listing_max_providers":100,"offer_key":"0x0f","offer_expires_in_seconds":3600,"agreement_key":"0x9c","agreement_port":20007,"agreement_glm_per_request":"0.001","agreement_expires_in_seconds":259200,"tunnel_state":"current","tunnel_agreement":"0x9c","tunnel_port":20007,"count":48213,"count_written_seconds_ago":600,"count_opened_seconds_ago":1800,"count_opened_block":900,"count_record":"0xc1","awaiting_records":1,"awaiting_requests":100,"payouts_receipts":1,"payouts_total_glm":"0.25","payouts_last_tx":"0x925d","payouts_last_chain_id":560048,"next":null}'
MARKETPLACE_STATUS=$pool status > "$tmp/out"
grep -q 'overall: *NOT SERVING YET' "$tmp/out"   # the tunnel profile is off
grep -q 'next: *connect the tunnel' "$tmp/out"
grep -q '^ *Load balancer: pays 0.001 GLM per request, 7 of 100 slots taken' "$tmp/out"
grep -q '^ *Offer: 0x0f, expires in about 60 minutes' "$tmp/out"
grep -q '^ *Agreement: 0x9c, tunnel port 20007, 0.001 GLM per request, ends in about 3 days unless the tunnel connects' "$tmp/out"
grep -q '^ *Tunnel: configured for this agreement' "$tmp/out"
grep -q '^ *Counting: 48213 requests as of the last write, about 10 minutes ago (since block 900, record 0xc1)' "$tmp/out"
grep -q '^ *Awaiting payout: 1 closed record, 100 requests' "$tmp/out"
grep -q '^ *Payouts: 1 receipt, 0.25 GLM in total; last transfer 0x925d on chain 560048' "$tmp/out"
MARKETPLACE_STATUS=$pool PROFILES=tunnel TUNNEL_STATUS_PORT=18601 status > "$tmp/out"
grep -q 'overall: *SERVING' "$tmp/out"
grep -q '^ *Agreement: 0x9c, .*kept alive by the load balancer while your node serves; ends in about 3 days if that stops' "$tmp/out"
MARKETPLACE_STATUS=$pool PROFILES=tunnel TUNNEL_STATUS_PORT=18601 status --json | grep -q '"serving":true,"next":null'
MARKETPLACE_STATUS=$pool PROFILES=tunnel TUNNEL_STATUS_PORT=18601 status --json | grep -q '"pool":{"count":48213,"error":null}'
# A note after the object does not stop the script: the object is the
# last line that is one.
MARKETPLACE_STATUS=$(printf '%s\n%s' "$pool" "a note after the object") status | grep -q 'overall: *NOT SERVING YET'
# A span the object lacks reads as unknown; a span of zero is "now".
MARKETPLACE_STATUS='{"address":"0x2121","balance_glm":"1","offer_key":"0x0f","agreement_key":null,"tunnel_state":"unconfigured","count":null,"awaiting_records":0,"payouts_receipts":0,"next":"acceptance"}' status > "$tmp/out"
grep -q '^ *Offer: 0x0f, expires in an unknown time' "$tmp/out"
grep -q 'next: *waiting for the load balancer' "$tmp/out"
MARKETPLACE_STATUS=${pool//\"offer_expires_in_seconds\":3600/\"offer_expires_in_seconds\":0} status | grep -q '^ *Offer: 0x0f, expires now'
# The records out of reach: the verdict says so instead of guessing, and
# everything the command printed is under the pool line.
status > "$tmp/out"
grep -q 'pool: *marketplace status could not run:$' "$tmp/out"
grep -q '^ *your node is not answering: is it running? (docker compose ps)$' "$tmp/out"
grep -q '^ *fetch failed$' "$tmp/out"
grep -q 'next: *cannot tell' "$tmp/out"
status --json | grep -q '"next":"unknown"'
status --json | grep -q '"pool":{"count":null,"error":"your node is not answering: is it running? (docker compose ps) fetch failed"}'
kill "$local_node" "$reference"; wait 2>/dev/null || true
trap - EXIT
rm -rf "$tmp"

note "the stack validates with every profile enabled"
COMPOSE_PROFILES=tunnel,monitor,marketplace docker compose config -q

note "the marketplace image builds and its entrypoint answers"
docker compose --profile marketplace build -q marketplace
# No command: the usage, exit code 2. The one run that needs no key,
# no node and no terminal.
if docker compose --profile marketplace run --rm -T marketplace >/dev/null 2>&1; then
  echo "the marketplace container accepted an empty command" >&2; exit 1
fi

note "all green"
