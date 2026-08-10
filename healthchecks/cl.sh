#!/usr/bin/env bash
# Beacon-node health: /eth/v1/node/health answers 200 (ready and in sync).
# 206 means still syncing — unhealthy for this check, which start_period
# covers after a start; 503 or silence means broken.
#
# Pure bash over /dev/tcp: see el.sh.
set -eu

exec 3<>/dev/tcp/127.0.0.1/5052
printf 'GET /eth/v1/node/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3
IFS= read -r status_line <&3
case "$status_line" in
  *" 200 "*) exit 0 ;;
  *) printf '%s\n' "$status_line" >&2; exit 1 ;;
esac
