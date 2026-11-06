#!/usr/bin/env bash
# cl-start.sh — the consensus container's entrypoint: registers the
# network's boot nodes as trusted peers of the beacon node, then runs it.
#
# Lighthouse's --trusted-peers takes bare peer ids and never dials them;
# POST /lighthouse/add_peer with an ENR pins the peer's score, so the
# beacon node never drops it for timeouts, and re-dials it every
# heartbeat while it is disconnected. That set lives in the process's
# memory, so it is registered at every start of the container, the
# restart after a host reboot included. The registration runs beside
# the beacon node, retrying until its API answers; the beacon node is
# the main process, and the container's init reaps the registration's
# subshell when it is done.
#
# The HTTP goes through bash's TCP redirection: the image carries no
# HTTP client. LIGHTHOUSE_API is where the beacon API listens inside the
# container; the tests point it at a fake.
set -u

api=${LIGHTHOUSE_API:-127.0.0.1:5052}

register(){
  local enr body status
  for enr in ${CL_ENRS//,/ }; do
    body="{\"enr\":\"$enr\"}"
    { exec 3<>"/dev/tcp/${api%:*}/${api##*:}"; } 2>/dev/null || return 1
    printf 'POST /lighthouse/add_peer HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$api" "${#body}" "$body" >&3
    read -r -t 5 status <&3 || status=
    exec 3>&-
    case $status in *" 200 "*) ;; *) return 1;; esac
  done
}

# Forked twice, so the job is init's child, not the beacon node's: the
# beacon node never waits for it, and a child it does not wait for would
# stay a zombie.
( ( until register; do sleep 5; done
    echo "registered the boot nodes as trusted peers of the beacon node" ) & )

exec "$@"
