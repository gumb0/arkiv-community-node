#!/usr/bin/env bash
# Joining the community RPC marketplace, one command per step. Each
# command runs in the marketplace container from the compose stack, as
# your own user, so the key file it writes is yours. See the README,
# "Joining the marketplace".
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'USAGE'
usage: ./marketplace.sh <command>

  create-key    create your provider key (once)
  post-offer    offer your node to the load balancer
  status        your offer, agreement, counts and payouts
USAGE
}

# One command in the container. --user keeps files it writes (the key)
# owned by you, not by the container's user.
run() {
  docker compose --profile marketplace run --rm --user "$(id -u):$(id -g)" marketplace "$@"
}

command="${1:-}"
case "$command" in
  create-key|post-offer|status) run "$command" ;;
  -h|--help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
