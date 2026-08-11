#!/usr/bin/env bash
# Execution-client health: the RPC socket answers with valid JSON-RPC —
# "up and serving". This check makes no claim about being current: reth's
# eth_syncing reports pipeline state, which stays false while the beacon
# node feeds blocks over the engine API. Whether the node is at the chain
# tip is the consensus healthcheck's job (cl.sh) — the beacon node knows
# that locally.
#
# Pure bash over /dev/tcp: the image ships bash but no curl or wget.
set -eu

body='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
exec 3<>/dev/tcp/127.0.0.1/8545
printf 'POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
  "${#body}" "$body" >&3
grep -q '"jsonrpc": *"2.0"' <&3
