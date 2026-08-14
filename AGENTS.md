# AGENTS.md

Guidance for coding agents working in this repository.

## What this repository is

The node-operator distribution for community-run Arkiv RPC nodes: a Compose
stack around the official Arkiv client images, plus the scripts an operator
needs to set up, check, and connect their node. The audience is volunteers on
their own machines — some non-native English speakers, many not professional
sysadmins.

## Hard rules

- **Self-contained.** This repo is cloned alone and must work alone: no path,
  script, or doc may reference anything outside the repo root. The companion
  load-balancer repo (`arkiv-community-lb`) depends on this one at test time;
  the dependency never points the other way.
- **The node is standard.** Official Arkiv execution + consensus images,
  consumed as-is — never forked, never patched.
- **No secrets in the repo.** Machine-local secrets (engine-API JWT, keys,
  tunnel token) are generated or supplied on the operator's machine; the `.env`
  file is the only place operator values live, and only a `.env.example` is
  committed.
- **Config split:** network values (genesis, chain id, bootnodes, image
  versions) come from the shared artifacts and are never hand-edited; operator
  values live in `.env`. Keep the two strictly apart — re-genesis of the devnet
  must stay "one refresh command plus a resync".

## Conventions

- Scripting is bash + `envsubst` templating, deliberately boring: an operator
  should be able to read a template and see what it produces.
- Docker healthchecks use local data only and never call anything outside the
  machine. Each badge has a precise claim — execution: serving JSON-RPC;
  consensus: the node is current, by the beacon node's own view. Anything
  involving the official RPC belongs to the status script
  (see `docs/DESIGN.md` for the full model).
- The compose stack is a hand-made translation of the network operator's own
  node-running script; `setup.sh` warns when that script changes upstream, and
  the answer is to re-review and adapt the translation — never to suppress the
  warning. Artifact parsing stays byte-compatible with upstream's own scripts:
  being more tolerant would hide upstream formatting problems.
- `tests/ci.sh` is the entire test suite, runnable locally; it must pass
  before committing. CI runs the same script — do not add checks to the
  workflow directly.
- Provider tooling is TypeScript on the official Arkiv SDK, run in a container
  so operators never install Node on the host.
- Prose (README, comments) targets non-native readers: simple words, short
  sentences, no informal jargon.
