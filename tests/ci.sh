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
rm -rf "$tmp"

note "the stack validates with every profile enabled"
COMPOSE_PROFILES=tunnel,monitor,marketplace docker compose config -q

note "all green"
