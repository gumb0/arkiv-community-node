# Changelog

Notable changes per release, newest first. The update procedure is the
same for every release: `git pull` in this clone, then `./setup.sh`.
An "Upgrade notes" line appears only when a release needs more than
that.

## Unreleased

- The offer's `mem_gb` is the machine's memory as the kernel maps it,
  what `lsmem` sums, so a 16 GB machine posts 16 where it posted 15: the
  kernel's own total leaves out what the kernel keeps for itself.
- The execution client gets `ARKIV_STORE_PATH=/data/golemdb`, as the
  network operator's script sets it since 2026-10-27: the directory of
  the Arkiv store that newer client versions run inside the node, in
  the datadir volume beside reth's database. The current image ignores
  it; `./setup.sh` recreates the container with it.
- The beacon node runs with optimistic finalized sync off, as the
  network operator's script does since 2026-10-26: it hands every
  finalized block to the execution layer while it syncs, so the
  execution layer catches up after a long stop. `./setup.sh` recreates
  the consensus container with the flag.
- `marketplace.sh status` says when the tunnel is configured for an
  agreement that has ended, and what to do: post a new offer, then
  run `start-tunnel` again.
- `./preflight.sh` checks a machine before setup: the architecture,
  the commands the scripts use, the memory and disk Docker has, whether
  the disk is rotational, the clock, and the local ports. One line per
  check with what to fix; exit 1 when something blocks setup. `setup.sh`
  runs it on its first run and stops on a failure (`SKIP_PREFLIGHT=1`
  goes on anyway).
- `setup.sh` refuses a network whose `metadata.yaml` has a chain id
  that is not a number, or a name or base domain that is not a DNS
  name.
- The network is chosen by name: `NETWORK=tiramisu` in `.env`, and
  `setup.sh` clones the network operator's registry of networks (now
  public) into `db-chain-networks/` on the first run, finds the network's
  directory in it, and pulls it on `--refresh`. `NETWORK_DIR` stays as
  the way to point at an artifacts directory of your own; an existing
  `.env` keeps working as it is.
- The snapshot restore image upgrades its CA bundle past the base
  image's, as the network operator's script does since 2026-10-22, so
  a snapshot host whose certificate chain needs a newer root still
  downloads.
- The network operator restructured the artifacts repository on
  2026-10-22: the networks moved under `networks/<cluster>/<name>`
  (tiramisu is `networks/testnet/tiramisu`) and the history was
  rewritten. An existing clone cannot be pulled; reset it to the
  published branch (`git fetch && git reset --hard origin/main`) and
  set `NETWORK_DIR` in `.env` to the new path. The upstream drift
  check follows the new path; the script it checks is unchanged.
- `setup.sh` no longer warns about a changed upstream `run-node.sh`.
  The warning asked an operator to judge a diff that is this
  repository's to review; the check now runs in this repository's CI
  against the recorded reviewed version (`tests/upstream-drift.sh`).
- The snapshot restore decodes the compression the manifest names,
  zstd as well as gzip. The network's snapshots are zstd since
  2026-10-14, and a fresh install's restore failed on them with "tar:
  invalid magic" (#20). A manifest naming neither is refused before
  anything is fetched, as the network's own script does.
- `marketplace.sh status` says when the count was last written ("as
  of the last write, about 2 hours ago"), and, for a record still at
  the 0 it was opened with, that requests served since the last write
  are not in it yet.
- `marketplace.sh status` says first when the node is still syncing,
  since what it shows may be out of date, and `start-tunnel` with no
  agreement in view says the node may not see it yet rather than
  "post an offer".
- `status.sh` tells a syncing node from a ready one: its last line
  says READY, SYNCING, or NEEDS ATTENTION, and `--json` gains `ready`.
  A healthy sync is still no fault, so the exit code stays 0 while the
  node catches up.
- The tunnel token is readable by its owner alone: with the tunnel on,
  `setup.sh` narrows `.env` to 0600 and writes the rendered tunnel
  config as 0600. An existing deployment's next `./setup.sh` narrows
  both.
- The first sync restores the network's published snapshot (README,
  "First sync"): when both chain volumes are empty, `setup.sh` runs the
  restore in a small image of its own, every layer verified against the
  manifest, and asks before syncing from genesis when there is nothing
  to restore; `FROM_GENESIS=1` skips it. `status.sh` says which
  snapshot the node started from.
- A re-genesis that keeps `genesis.json` is detected: setup records the
  consensus genesis time beside the genesis hash, and either changing
  is a re-genesis. An existing deployment's first run records the time
  quietly.
- The re-genesis wipe removes the two chain volumes only; the
  monitor's data stays. `./setup.sh --wipe` runs the same wipe for a
  resync from scratch, and every hint that said `down -v` says that.
- `marketplace.sh status`: payouts made by an earlier settle key count,
  after a rotation of that key. The previous settle addresses ship in
  `marketplace/addresses.json` next to the current one; none for
  tiramisu today. `SETTLE_PREVIOUS_ADDRESSES` in `.env` overrides
  them.
- `setup.sh` rebuilds the marketplace commands' image. Before, an
  update left `marketplace.sh` running the old code until the image
  was removed.
- The marketplace commands' Node image moves to 22.23.4, the current
  security release. The commands reach only this node, over the
  compose network, so the CA bundle in the image plays no part; the
  bump is routine.

Upgrade notes: run `./setup.sh` after this update, even if nothing
else changed, so the marketplace commands run the new code. Update
your machine's own CA bundle too (`apt update && apt upgrade
ca-certificates` on Debian and Ubuntu).

## v0.2.1

- README: the node images are public, so no registry login is needed
  before `./setup.sh`; and the tunnel token in `.env` and the rendered
  tunnel config admits a tunnel as this node, so those files are as
  private as the key.

## v0.2.0

- `marketplace.sh`: joining the community RPC marketplace, one command
  per step, each run in a container from the stack (the `marketplace`
  profile, never started by `up`):
  - `create-key` makes the provider key as a standard encrypted
    keystore file in `secrets/`.
  - `post-offer` posts the node's specs as an offer to the load
    balancer, through the node itself, after checking every reason the
    offer would be skipped.
  - `status` shows the offer, the agreement, the counts and the payouts
    from the records, and whether the tunnel is set up for the current
    agreement.
  - `start-tunnel` signs the agreement id with the key, writes the
    tunnel settings into `.env` and starts the tunnel.

  The two addresses the records are trusted by, the load balancer's
  and the settle key's that writes the payout receipts, ship in
  `marketplace/addresses.json` per chain; `LB_ADDRESS` and
  `SETTLE_ADDRESS` in `.env` override them.
- The tunnel is admitted by the signed token, not by a shared
  password: `TUNNEL_AUTH_TOKEN` is gone, and `TUNNEL_SERVER_PORT`,
  `TUNNEL_AGREEMENT` and `TUNNEL_TOKEN` join the tunnel settings, all
  five written by `start-tunnel`.

Upgrade notes: a tunnel configured by hand with the shared token no
longer connects. Join through the marketplace (`create-key`,
`post-offer`, then `start-tunnel` once the offer is accepted); until
then, remove `tunnel` from `COMPOSE_PROFILES` so `./setup.sh` does not
stop on the missing settings.

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
