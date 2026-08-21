# Design — Arkiv Community Node distribution

**Scope:** how this distribution is built and why — the compose stack, the
setup and status scripts, and the health model. The operator-facing "how do
I use it" lives in the [README](../README.md); this document explains the
shape of the machinery behind it.

---

## 1. Goals and constraints

The distribution exists so that someone outside the network operator's
infrastructure can run an Arkiv RPC node and *know whether it is working*.
Throughout this document, the **operator** is the person running the node;
the **network operator** is the party publishing the chain's artifacts and
running its infrastructure. The audience sets the constraints:

- **Volunteer-first.** No service the operator must learn beyond Docker.
  Anything optional is an opt-in overlay, never a requirement.
- **Boring, inspectable tools.** Bash and `envsubst`, no templating engine:
  an operator should be able to read any file in this repo and see what it
  does to their machine. Rendering is inspectable before anything runs
  (`setup.sh --render-only`).
- **The node is standard.** Official execution and consensus images,
  consumed as-is — this repo wraps the node, it never modifies it.
- **No secrets shipped.** The only secret the stack needs — the JWT the two
  clients use to authenticate their internal engine-API connection — is
  generated on the operator's machine on first run; nothing secret exists
  in the repo, and no API key needs to be obtained from anyone.

## 2. The pieces

```
 network operator                     operator's machine
┌──────────────────┐   git clone   ┌─────────────────────────────────────┐
│ network artifacts│ ────────────► │ artifacts clone (any path)          │
│ repo: genesis,   │               │        │ setup.sh: verify checksums,│
│ checksums, peer  │               │        │ detect changes, copy in,   │
│ endpoints, image │               │        ▼ build configuration        │
│ pins             │               │ ┌──────────────────────────────┐    │
└──────────────────┘               │ │ compose stack                │    │
                                   │ │  execution client            │    │
                                   │ │       ▲ engine API           │    │
                                   │ │  beacon node                 │    │
┌──────────────────┐               │ └──────────────────────────────┘    │
│ official RPC     │               │ health badges ── docker compose ps  │
│ (the reference)  │ ◄─────────────┼── status.sh compares local head     │
└──────────────────┘               │   against the reference             │
                                   └─────────────────────────────────────┘
```

| Piece | Job |
|---|---|
| `compose.yaml` | The stack's stable structure: mounts, ports, health checks, restart policy, log rotation — no network-specific values |
| `compose.override.yaml` (generated) | Image pins and client command lines, with the network's peer endpoints substituted in; regenerated on every setup, never edited by hand |
| `setup.sh` | Verify → detect changes → build configuration → start; re-running is the update procedure, and nothing is wiped without asking |
| `status.sh` | Chain-level truth on demand, including a comparison against the official RPC; operator-invoked, separate from the health badges |
| `healthchecks/*.sh` | The badge predicates, running inside the containers on local data only ([health model](#4-health-model)) |
| `tunnel/`, `frpc.toml` (generated) | The optional tunnel client: a locally built image and its rendered config ([the tunnel](#6-the-tunnel-optional)) |

## 3. Configuration model

Two kinds of configuration with different owners, kept strictly apart:

- **Network values** — genesis, checksums, peer endpoints, image pins —
  come from the network operator's artifacts directory and are never edited
  by hand. When the network changes, a refresh regenerates everything
  derived from them.
- **Operator values** — the artifacts path and local port numbers — live in
  `.env`, the only file an operator edits.

The stack never reads the operator's artifacts clone directly: `setup.sh`
checks the clone against its published checksums, copies it into the repo
directory, and the containers mount that **verified copy**. The running
node never depends on where the operator keeps their clone, and changes in
the clone take effect only through a setup run — which re-verifies first.

Three change detectors decide what a setup run does:

- **If the genesis differs** from the one the chain data was synced from —
  a re-genesis, the old data belongs to a dead chain — setup wipes the
  chain data (asking for confirmation first). Declining stops the run with
  nothing modified.
- **If the artifacts' checksum file differs** from the last applied copy,
  setup copies the artifacts fresh and recreates the containers, so the
  clients actually load the new files — container configuration alone
  would not notice content changes behind a bind mount.
- **If the network operator's own node-running script changed** since this
  stack was last reviewed against it, setup warns. The compose stack is a
  hand-made translation of that script; after an upstream change, the
  translation needs a human look before it can be trusted again.

An unchanged re-run passes through all three without touching anything —
`setup.sh` is convergent, and "re-run setup" is always a safe instruction.
Profiles converge the same way: a service whose profile was turned off is
stopped by the next setup run — compose alone would leave it running.

## 4. Health model

Two badges with different claims, visible in `docker compose ps`:

- **execution: healthy** = serving valid JSON-RPC. Nothing more — the
  execution client cannot reliably judge its own currency: it is driven by
  the beacon node over the engine API, and its own sync flag
  (`eth_syncing`) reports an internal pipeline state that can read `false`
  while the node is still far behind the chain.
- **consensus: healthy** = the whole node is current. The beacon node knows
  the chain tip locally, and its syncing endpoint states the three needed
  facts explicitly: at the tip, execution validated up to it, engine API
  alive.

The node is OK when both are green. Design rules behind the model:

- **Local checks stay local.** Health never depends on the network
  operator's endpoint being reachable — a reference outage must not turn
  every community node red at once. Chain-level truth against the reference
  belongs to `status.sh`, invoked by a human.
- **Badges signal, they do not act.** Nothing auto-restarts an
  unhealthy-but-alive container: an automatic restarter can destroy a slow
  recovery, and it would need privileges this distribution has no business
  asking for. The restart decision is the operator's.
- The checks (`healthchecks/el.sh` for execution, `healthchecks/cl.sh` for
  consensus) are pure bash over `/dev/tcp` inside the containers — the
  images ship no HTTP client, and mounting one in would mean maintaining a
  fork of "standard".

## 5. The status script

`status.sh` answers what badges cannot: right chain, current head and its
age, peer counts per layer, and whether the local view matches the official
RPC. Its design rules:

- **A reference problem is never this node's fault.** Unreachable, rate
  limited, or answering strangely — the script reports "local view only"
  and the verdict is unaffected. Only local faults (wrong chain, a
  confirmed hash mismatch, a client not answering, a beacon with zero
  peers — new blocks cannot arrive) fail it.
- **A missing comparison is "unknown", never a mismatch.** Hash mismatch is
  the scariest thing the script can say — it must mean exactly that, with
  both hashes printed as evidence.
- **Hashes are compared at the highest height both sides have**, so the
  comparison works mid-sync, at the tip, and when the reference lags. The
  head can be reorged, so the output asks for a re-run before advising a
  resync.
- **Frugal with the metered reference:** the official RPC is rate limited,
  so the script makes one request in the common case (the reference's head
  block carries number and hash together) and a second only while this
  node is behind. It uses the public endpoint as-is — no API key involved.
- Every failure line says what to do next, not only what is wrong.

## 6. The tunnel (optional)

A node behind NAT cannot be reached from outside; the distribution can
serve its JSON-RPC through a **tunnel server** instead. This is an opt-in
overlay: a compose profile, off by default, enabled by one `.env` line
plus three values the tunnel server operator provides (server address,
auth token, assigned port). The tunnel client is
[frp](https://github.com/fatedier/frp); it opens one outbound connection
and keeps retrying on its own when the server is away, so a server
restart needs no action from the operator.

Design choices:

- **The client runs inside the compose stack**, not as a host process —
  one lifecycle for everything (`up`, `down`, logs, restart policy).
- **The image is built locally** from the pinned upstream release, checksum
  verified in the Dockerfile — no third-party image to trust, same trust
  chain as everything else in the stack.
- **Configuration follows the [model](#3-configuration-model):** the
  `TUNNEL_*` values are operator values in `.env` (the token is a secret
  and stays there), and the client config is rendered from a template by
  `setup.sh` like the rest.
- **"Up" does not mean "connected", so the tunnel gets its own badge.** The healthcheck asks the
  client's own local status endpoint whether the proxy is running, and
  `status.sh` reports the same distinction.

## 7. Monitoring (optional)

The badges signal, `status.sh` answers on demand — but both wait to be
looked at. The monitor profile adds the missing piece: an on-box
[Uptime Kuma](https://github.com/louislam/uptime-kuma) that alerts the
operator when a badge-level fact goes bad. Notifications go outbound
(Telegram, email, …), so alerting works unchanged for a node behind NAT.
Another opt-in overlay, off by default, enabled by one `.env` line.

Design choices:

- **It watches the same local endpoints the badges do** — from inside the
  compose network, so the suggested monitors cannot accidentally point at
  the metered official RPC; the README states that rule explicitly.
- **The UI answers on loopback only** — a browser on the node machine
  itself, or SSH port forwarding from a headless box. There is no setting
  to bind it wider: the UI holds an admin account, and forwarding covers
  the headless case safely. Monitor setup stays manual in the UI — a
  provisioning mechanism for a five-minute one-time task would be more
  machinery than the task.
- **It observes, it never acts.** The restart decision stays with the
  operator ([health model](#4-health-model)); a watchdog that acts is a
  separate future item, deliberately downstream of alerting.

## 8. Testing

`tests/ci.sh` holds the entire test suite in one script, runnable locally
and run identically by CI: shellcheck over every script, a render through
the real `setup.sh` against a committed fixture network (dummy addresses,
real checksums — setup verifies them like the real thing), a validation of
the merged compose stack, and assertions that the fixture values landed in
the output.

## 8. Possible future improvements

- **Restart watchdog**: an optional watchdog that restarts
  unhealthy-but-alive containers — also an opt-in overlay, default off:
  the base stack stays signals-only ([health model](#4-health-model)).
- **Data-location knob**: chain data lives in Docker named volumes;
  putting it on another disk today means moving Docker's whole data root.
  A knob for the data location would be friendlier.
- **Per-service restart on artifact changes**: recreating only the
  container whose files changed needs a map of which client reads which
  artifact file, and that map must stay correct forever as the artifacts
  evolve. For now a spare restart costs seconds and no data (chain data
  lives in named volumes and recreation does not touch it), so any
  artifacts change recreates both containers.
- **Named reference RPC errors**: `status.sh` reports every reference
  problem as "unreachable". Naming the reason (rate limited vs down vs a
  network problem) would save the operator a guess.
- **Fork-proof hash comparison**: `status.sh` compares hashes at the
  current head, which can briefly disagree during a fork at the tip.
  Comparing at a finalized (or simply older) height would remove that
  caveat.
- **Image pins as data**: image pins and the official RPC URL are
  currently read out of the network operator's script and derived by
  convention. If the artifacts ever publish them as data, setup should
  consume that instead.
