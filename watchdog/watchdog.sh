#!/bin/sh
# Restarts a watched container after it stays unhealthy for
# WATCHDOG_UNHEALTHY_POLLS consecutive polls, at most once per
# WATCHDOG_COOLDOWN_SECONDS. The only input is docker's own health
# status: "starting" and "healthy" reset the streak, so a first sync
# inside start_period is never touched. Why this is opt-in and what
# mounting the docker socket grants: see the README and docs/DESIGN.md.
#
# No set -e: one failed docker call must not kill the loop.
set -u

POLL="${WATCHDOG_POLL_SECONDS:-60}"
NEEDED="${WATCHDOG_UNHEALTHY_POLLS:-5}"
COOLDOWN="${WATCHDOG_COOLDOWN_SECONDS:-3600}"
STATE=/tmp/watchdog
mkdir -p "$STATE"

# The compose project is read from this container's own labels (the
# default hostname is the container id), so the stack's name is not
# repeated here.
project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$(hostname)") || {
  echo "watchdog: cannot inspect own container — is the docker socket mounted?" >&2
  exit 1
}
[ -n "$project" ] || { echo "watchdog: own container carries no compose project label" >&2; exit 1; }

echo "watchdog: project $project, poll ${POLL}s, restart after $NEEDED unhealthy polls, cooldown ${COOLDOWN}s"

while :; do
  # Watched set is fixed: the tunnel client reconnects on its own and the
  # monitor manages itself — a restart cures neither.
  for service in execution consensus; do
    streak_file="$STATE/streak.$service"
    cid=$(docker ps -q \
      --filter "label=com.docker.compose.project=$project" \
      --filter "label=com.docker.compose.service=$service") || cid=""
    if [ -z "$cid" ]; then
      # Not running at all: starting and stopping are compose's business.
      rm -f "$streak_file"
      continue
    fi
    health=$(docker inspect -f '{{ if .State.Health }}{{ .State.Health.Status }}{{ end }}' "$cid" 2>/dev/null) || health=""
    if [ "$health" = unhealthy ]; then
      streak=$(( $(cat "$streak_file" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$streak" > "$streak_file"
      [ "$streak" = 1 ] && echo "watchdog: $service is unhealthy (1/$NEEDED)"
      last=$(cat "$STATE/restarted.$service" 2>/dev/null || echo 0)
      if [ "$streak" -ge "$NEEDED" ] && [ $(( $(date +%s) - last )) -ge "$COOLDOWN" ]; then
        echo "watchdog: $service unhealthy for $streak polls — restarting it"
        if docker restart "$cid" >/dev/null; then
          date +%s > "$STATE/restarted.$service"
          rm -f "$streak_file"
        else
          echo "watchdog: restarting $service failed" >&2
        fi
      fi
    else
      rm -f "$streak_file"
    fi
  done
  sleep "$POLL"
done
