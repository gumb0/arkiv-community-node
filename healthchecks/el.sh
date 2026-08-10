#!/usr/bin/env bash
# Execution-client health: the RPC socket answers and the node reports
# "not syncing" (eth_syncing == false). A real JSON-RPC round trip, so a
# pass means "up and serving reads".
#
# Pure bash over /dev/tcp on purpose: the image ships bash but no curl or
# wget. Chain-level truth (right chain, current head) is status.sh's job,
# not this check's.
set -eu

body='{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}'
exec 3<>/dev/tcp/127.0.0.1/8545
printf 'POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
  "${#body}" "$body" >&3
grep -q '"result":false' <&3
