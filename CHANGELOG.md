# Changelog

Notable changes per release, newest first. The update procedure is the
same for every release: `git pull` in this clone, then `./setup.sh`.
An "Upgrade notes" line appears only when a release needs more than
that.

## Unreleased

- `marketplace.sh`: the first steps of joining the community RPC
  marketplace. `create-key` makes the provider key as a standard
  encrypted keystore file in `secrets/`; `post-offer` posts the node's
  specs as an offer to the load balancer, through the node itself,
  after checking every reason the offer would be skipped; `status`
  shows the offer, the agreement, the counts and the payouts from the
  records. Runs in a
  container from the stack (the `marketplace` profile, never started by
  `up`). The load balancer's address ships in `marketplace/addresses.json`,
  per chain; `LB_ADDRESS` in `.env` overrides it.

## v0.1.1

- The tunnel proxy name is derived from the assigned remote port. The
  fixed name let only the first connected node register; every later
  node was rejected with `proxy already exists`.
- The consensus healthcheck start period is a full day. A fresh sync
  outlasted the previous six hours and the container turned falsely
  unhealthy for the rest of it.
- The consensus image pin is read from the upstream network script,
  the same way as the execution pin, so it cannot drift. Setting
  `CL_IMAGE` in the environment or `.env` no longer overrides it.
- The monitor recipe's "Node current" keyword checks all three syncing
  flags, matching the health badge.

Upgrade notes: `./setup.sh` re-renders `frpc.toml` and recreates the
tunnel container with the new proxy name; if the tunnel is on, run it
even if nothing else changed.

## v0.1.0

First release: compose stack with checksum-verified setup, status
script, tunnel and monitor profiles.
