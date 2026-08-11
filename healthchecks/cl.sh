#!/usr/bin/env bash
# Consensus health carries the "is this node current" truth — the beacon
# node knows the chain tip locally. /eth/v1/node/syncing states all three
# conditions explicitly:
#   is_syncing:false    — the beacon chain is at the tip
#   is_optimistic:false — the execution client has validated up to it
#   el_offline:false    — the engine API connection is alive
# Green here means the whole node serves current data.
#
# Pure bash over /dev/tcp: see el.sh.
set -eu

exec 3<>/dev/tcp/127.0.0.1/5052
printf 'GET /eth/v1/node/syncing HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3
response=$(cat <&3)
printf '%s' "$response" | grep -q '"is_syncing": *false'
printf '%s' "$response" | grep -q '"is_optimistic": *false'
printf '%s' "$response" | grep -q '"el_offline": *false'
