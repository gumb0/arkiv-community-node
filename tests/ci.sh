#!/usr/bin/env bash
# The CI gate, runnable locally: exactly what .github/workflows/ci.yml runs.
set -euo pipefail
cd "$(dirname "$0")/.."

note(){ printf '== %s\n' "$*"; }

note "shellcheck every shell script"
git ls-files '*.sh' | xargs -r shellcheck

note "render through setup.sh against the fixture network"
NETWORK_DIR=tests/fixture-network ./setup.sh --render-only

note "validate the merged stack"
docker compose config -q

note "rendered output carries the fixture values"
grep -q 'fixture-el:ci' compose.override.yaml
grep -q '192.0.2.10:30000,enode://' compose.override.yaml
grep -q 'enr:-fixture-aaaa,enr:-fixture-bbbb' compose.override.yaml

note "tunnel render carries the operator values"
NETWORK_DIR=tests/fixture-network COMPOSE_PROFILES=tunnel \
  TUNNEL_SERVER_ADDR=203.0.113.7 TUNNEL_AUTH_TOKEN=ci-token TUNNEL_REMOTE_PORT=18545 \
  ./setup.sh --render-only
grep -q 'serverAddr = "203.0.113.7"' frpc.toml
grep -q 'remotePort = 18545' frpc.toml

note "the stack validates with the tunnel profile enabled"
COMPOSE_PROFILES=tunnel docker compose config -q

note "all green"
