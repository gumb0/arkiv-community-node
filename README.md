# Arkiv Community Node

Tooling for running an [Arkiv](https://arkiv.network) RPC node and, later, for joining it to the community
read endpoint (`community.rpc.arkiv.network`) as a paid provider.

The node is two containers: the Arkiv execution client (serves JSON-RPC
reads) and a Lighthouse beacon node (follows the chain and drives the
execution client). This repo wraps them in a Compose stack with health
checks, a status script, and a one-command setup.

## Prerequisites

- A Linux x86_64 machine with Docker and the compose plugin
  (`docker compose version` must work — see the
  [official install guide](https://docs.docker.com/engine/install/)),
  plus `git`, `openssl`, and `envsubst` (Debian/Ubuntu:
  `apt install gettext-base`).
- An NTP-synced clock (`timedatectl` shows "synchronized: yes" on most
  systems). Consensus is slot-timed; a drifting clock desynchronizes the
  node.
- The **network artifacts directory** — genesis, checksums, peer
  endpoints — published by the network operator. During the current
  phase, access is granted by the operator; keep your copy as a git
  clone so it can be updated.
- Access to the network's container registry, if it is credentialed
  (`docker login` before setup).

## Quickstart

```bash
git clone https://github.com/gumb0/arkiv-community-node.git
cd arkiv-community-node
cp .env.example .env
# edit .env: set NETWORK_DIR to your network artifacts directory
./setup.sh
```

`setup.sh` checks the artifacts against their checksums, builds the
configuration from them, and starts the containers. Re-running is safe
at any time and is also the update procedure. `./setup.sh --help` lists
the flags.

## Is it working?

```bash
docker compose ps    # health badges
./status.sh          # chain-level view
```

The two health badges make different claims:

| Service | `healthy` means |
|---|---|
| execution | Serving JSON-RPC |
| consensus | The whole node is **current** — at the chain tip, fully validated |

| Badge | Meaning | What to do |
|---|---|---|
| `starting` | First sync in progress — takes **hours** (the chain syncs from genesis) | Wait; watch progress with `./status.sh` |
| `healthy` | See the table above | Nothing |
| `unhealthy` | Not serving, or stuck | Check logs; re-run `./setup.sh`; restart is up to you — nothing restarts containers automatically while they stay alive |

The node is OK when **both** badges are green.

`./status.sh` answers what the badges cannot: right chain, current head
and its age, peer counts, and whether your view matches the network's
official RPC. It tells you what to do when something is wrong.

## Everyday commands

```bash
docker compose ps                              # health at a glance
docker compose stop                            # stop the node (data kept)
docker compose up -d                           # start it again
docker compose restart consensus               # restart one service
docker compose logs -f --no-log-prefix execution   # follow one service's logs
docker system df                               # how much disk Docker uses
./status.sh                                    # chain-level view
./setup.sh --refresh                           # update from the network artifacts
```

## Endpoints (this host only)

Both APIs answer on loopback only — they are not reachable from the
internet:

- JSON-RPC: `http://127.0.0.1:8545` (port: `EL_RPC_PORT` in `.env`)
- Beacon API: `http://127.0.0.1:5052` (port: `CL_HTTP_PORT`)

## Updating

```bash
./setup.sh --refresh
```

This pulls the artifacts repo, checks it, rebuilds the configuration,
and restarts the containers if anything changed. An unchanged re-run
restarts nothing.

When the network is **re-genesised** (a devnet restart from a new
genesis), the old chain data belongs to a dead chain. Setup detects this
and asks before wiping; the node then resyncs from scratch.

**Careful with `down -v`:** `docker compose down` stops and removes the
containers but keeps the chain data — everything resumes where it left
off. `docker compose down -v` **deletes the chain data**; the next start
resyncs from genesis, which takes hours. Use it only when the output of
`setup.sh` or `status.sh` tells you to.

## Where the data lives

Chain data is stored in Docker named volumes — not in this directory.
If you want it on a bigger disk, point Docker's data root there (this
moves all Docker data, which on a dedicated node machine is what you
want):

```bash
docker compose down                # stop the node first
sudo systemctl stop docker
sudo rsync -a /var/lib/docker/ /mnt/bigdisk/docker/
echo '{ "data-root": "/mnt/bigdisk/docker" }' | sudo tee /etc/docker/daemon.json
sudo systemctl start docker
docker compose up -d
```

(Merge the `data-root` key into `daemon.json` by hand if the file
already exists.)

## When something looks wrong

Run `./status.sh` first — for the common problems it names the cause and
the fix. Beyond that:

- **Setup fails at checksum verification** — your artifacts copy is stale
  or half-updated: `git pull` in the artifacts clone and re-run.
- **"The node did not come up"** — setup prints the failing container's
  last log lines; the message is usually explicit. A port already in use
  means another service holds 8545/5052 — change the port in `.env`.
- **A badge stuck at `starting` far longer than a first sync should
  take** — check `./status.sh`: if it says "level with the reference, but
  the chain is quiet", the network itself is paused; nothing to fix
  locally.
- **A container restarting in a loop** — `docker compose logs <service>`;
  the first error line names the cause.

## Known limitations

- The first sync runs from genesis and takes hours; the consensus badge
  stays at `starting` the whole time. There is no snapshot download.
- Nothing restarts an unhealthy-but-alive container automatically; the
  badges are signals for you, not a supervisor.
- `status.sh` compares hashes at the current head, which can briefly
  disagree during a fork — it says so, and asks you to re-run before
  acting.
- `status.sh` does not say why the official RPC could not be used: a down
  endpoint, a network problem, and a rate limit all show as
  "reference: unreachable". If you run it very often, a rate limit is the
  likely cause.
- An artifacts update briefly restarts both containers, even when the
  change affects only one of them. Chain data is not touched.

## License

[Apache-2.0](LICENSE)
