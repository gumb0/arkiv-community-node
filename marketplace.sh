#!/usr/bin/env bash
# Joining the community RPC marketplace, one command per step. Each
# command runs in the marketplace container from the compose stack, as
# your own user, so the files it writes are yours. See the README,
# "Joining the marketplace".
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: ./marketplace.sh <command>

  create-key    create your provider key (once)
  post-offer    offer your node to the load balancer
  status        your offer, agreement, counts and payouts
  start-tunnel  connect your node once the offer is accepted
USAGE
}

# One command in the container. --user keeps files it writes (the key,
# the tunnel settings) owned by you, not by the container's user.
run() {
  # Before setup.sh has run there is no secrets/ yet, and docker would
  # create the mounted directory as root, out of the operator's reach.
  mkdir -p secrets
  docker compose --profile marketplace run --rm --user "$(id -u):$(id -g)" marketplace "$@"
}

# merge_env <env file> <values file>: every NAME=VALUE line of the values
# file replaces the line setting NAME in the env file, or is appended
# when there is none. Other lines, comments included, are left alone.
merge_env() {
  local env_file=$1 values=$2 name value
  # Each line split at its first '=': the name, then the rest as the
  # value, so a value with an '=' in it stays whole.
  while IFS='=' read -r name value; do
    [ -n "$name" ] || continue
    if grep -q "^${name}=" "$env_file"; then
      sed -i "s|^${name}=.*|${name}=${value}|" "$env_file"
    else
      printf '%s=%s\n' "$name" "$value" >> "$env_file"
    fi
  done < "$values"
}

# enable_profile <env file> <profile>: adds the profile to
# COMPOSE_PROFILES, setting the line when there is none.
enable_profile() {
  local env_file=$1 profile=$2 current
  current=$(grep -E "^COMPOSE_PROFILES=" "$env_file" | head -1 | cut -d= -f2- || true)
  case ",${current}," in
    *,"$profile",*) return ;;
  esac
  local merged
  if [ -n "$current" ]; then merged="${current},${profile}"; else merged=$profile; fi
  printf 'COMPOSE_PROFILES=%s\n' "$merged" > "$env_file.profile"
  merge_env "$env_file" "$env_file.profile"
  rm -f "$env_file.profile"
}

# The container signs the token and leaves the tunnel settings in
# secrets/tunnel.env; they go into .env, the tunnel profile goes on,
# and setup.sh renders the client config and starts the tunnel.
start_tunnel() {
  rm -f secrets/tunnel.env
  run start-tunnel
  [ -f secrets/tunnel.env ] || { echo "the tunnel settings were not written" >&2; exit 1; }
  merge_env .env secrets/tunnel.env
  enable_profile .env tunnel
  rm -f secrets/tunnel.env
  echo "Tunnel settings written to .env. Starting the tunnel..."
  ./setup.sh
}

main() {
  cd "$(dirname "$0")"
  local command="${1:-}"
  case "$command" in
    create-key|post-offer|status) run "$command" ;;
    start-tunnel) start_tunnel ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

# Sourced by tests/ci.sh for its functions; run as a script otherwise.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
