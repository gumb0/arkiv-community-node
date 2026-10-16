#!/usr/bin/env bash
# The CI gate, runnable locally: exactly what .github/workflows/ci.yml runs.
set -euo pipefail
cd "$(dirname "$0")/.."

note(){ printf '== %s\n' "$*"; }

note "shellcheck every shell script"
git ls-files '*.sh' | xargs -r shellcheck

note "marketplace package: typecheck and unit tests"
(cd marketplace && npm ci --silent && npm run --silent typecheck && npm test)

note "render through setup.sh against the fixture network"
NETWORK_DIR=tests/fixture-network ./setup.sh --render-only

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
status(){ EL_RPC_PORT=18601 CL_HTTP_PORT=18601 COMPOSE_PROFILES='' NO_COLOR=1 "$tmp/status.sh" "$@"; }
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
status | grep -q 'overall: *READY'
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
