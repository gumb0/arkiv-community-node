#!/usr/bin/env bash
# setup.sh — prepare and start an Arkiv community node. See usage() below.
set -euo pipefail
cd "$(dirname "$0")"

die(){ printf 'setup.sh: %s\n' "$*" >&2; exit 1; }
note(){ printf '%s\n' "$*"; }

usage(){
  cat <<'EOF'
Usage: ./setup.sh [--refresh] [--render-only] [--yes]

Prepares and starts an Arkiv community node. Operator values come from
.env, or from environment variables, which win over the file. NETWORK_DIR
is required — the network artifacts directory (genesis, checksums, peer
endpoints) published by the network operator; everything else is optional.
The script renders compose.override.yaml from the template and starts the
stack. Re-running is safe and is also the update procedure.

  --refresh      git pull the artifacts repo first
  --render-only  stop after rendering, start nothing
  --yes          answer yes to the chain-data wipe prompt (see below)

When the network's genesis changes (a re-genesis), the old chain data is
useless and must be wiped before the node can follow the new chain. This
script detects the change and asks before wiping; it never wipes on its
own.
EOF
}

REFRESH=0 RENDER_ONLY=0 ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --refresh)     REFRESH=1;;
    --render-only) RENDER_ONLY=1;;
    --yes)         ASSUME_YES=1;;
    -h|--help)     usage; exit 0;;
    *)             usage >&2; die "unexpected argument: $arg";;
  esac
done

# Operator values. Real environment variables win over .env file — the same
# precedence docker compose uses for its own .env handling. Just sourcing .env
# would give the file precedence, so pre-set values are saved and restored.
env_network_dir="${NETWORK_DIR:-}"
env_el_port="${EL_RPC_PORT:-}"
env_cl_port="${CL_HTTP_PORT:-}"
env_cl_image="${CL_IMAGE:-}"
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null # .env does not exist on CI and linter would complain
  . ./.env
  set +a
fi
[ -n "$env_network_dir" ] && NETWORK_DIR="$env_network_dir"
[ -n "$env_el_port" ]     && EL_RPC_PORT="$env_el_port"
[ -n "$env_cl_port" ]     && CL_HTTP_PORT="$env_cl_port"
[ -n "$env_cl_image" ]    && CL_IMAGE="$env_cl_image"

# The consensus client image is pinned.
CL_IMAGE="${CL_IMAGE:-sigp/lighthouse:v8.2.1}"

# Prerequisites, checked before touching anything.
command -v docker >/dev/null || die "docker is not installed — see https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed (Debian/Ubuntu: apt install docker-compose-v2)"
command -v envsubst >/dev/null || die "envsubst is not installed (Debian/Ubuntu: apt install gettext-base)"
command -v openssl >/dev/null || die "openssl is not installed (Debian/Ubuntu: apt install openssl)"
[ -n "${NETWORK_DIR:-}" ] || die "NETWORK_DIR is not set.
Set it in .env to the network artifacts directory you received (see .env.example)."
[ -d "$NETWORK_DIR" ] || die "the network artifacts directory does not exist: $NETWORK_DIR
Check NETWORK_DIR in .env."

if [ "$REFRESH" = 1 ]; then
  command -v git >/dev/null || die "git is not installed (Debian/Ubuntu: apt install git)"
  note "Updating the artifacts repo..."
  git -C "$NETWORK_DIR" pull --ff-only
fi

# Verify the artifacts against the checksums the network publishes.
[ -f "$NETWORK_DIR/SHA256SUMS" ] || die "no SHA256SUMS in $NETWORK_DIR —
is this really a network artifacts directory? Check NETWORK_DIR in .env."
( cd "$NETWORK_DIR" && sha256sum --check --quiet SHA256SUMS ) \
  || die "artifact checksum verification failed in $NETWORK_DIR"

mkdir -p .setup-state

# Re-genesis detection: a changed genesis means the existing chain data
# belongs to a different chain.
genesis_sha=$(sha256sum "$NETWORK_DIR/genesis.json" | cut -d' ' -f1)
stored_genesis_file=.setup-state/genesis.sha256
if [ -f "$stored_genesis_file" ] && [ "$(cat "$stored_genesis_file")" != "$genesis_sha" ]; then
  if [ "$RENDER_ONLY" = 1 ]; then
    note "The network's genesis has changed. A normal setup run will offer to"
    note "wipe the chain data."
  else
    note "The network's genesis has changed — the existing chain data must be"
    note "wiped, and the node will resync from scratch."
    if [ "$ASSUME_YES" = 1 ]; then
      reply=y
    else
      printf 'Wipe chain data now? [y/N] '
      read -r reply || reply=n   # if no terminal to ask: default to no
    fi
    case "$reply" in
      y|Y) docker compose down -v
           rm -f "$stored_genesis_file"
           note "Chain data wiped.";;
      *)   note "Keeping the old chain data — nothing else was changed."
           note "The node cannot follow the new chain until it resyncs:"
           note "  docker compose down -v && ./setup.sh"
           exit 1;;
    esac
  fi
fi
# The record says which genesis the chain data was synced from, so it is
# written when there is no data yet — a first run, or just after a wipe.
# A declined wipe leaves the old record, and is detected again next time.
if [ ! -f "$stored_genesis_file" ] && [ "$RENDER_ONLY" != 1 ]; then
  printf '%s\n' "$genesis_sha" > "$stored_genesis_file"
fi

# Drift check: our compose translation follows the upstream run-node.sh.
# When upstream changes, the translation must be reviewed by a human —
# this cannot be automated away, only detected.
upstream_script="$NETWORK_DIR/run-node.sh"
if [ -f "$upstream_script" ]; then
  upstream_sha=$(sha256sum "$upstream_script" | cut -d' ' -f1)
  stored_upstream_file=.setup-state/upstream-run-node.sha256
  if [ -f "$stored_upstream_file" ] && [ "$(cat "$stored_upstream_file")" != "$upstream_sha" ]; then
    note "WARNING: the upstream run-node.sh changed since this stack was last"
    note "reviewed against it. Compare it with templates/compose.override.yaml.tmpl"
    note "before trusting the render."
  fi
  [ "$RENDER_ONLY" = 1 ] || printf '%s\n' "$upstream_sha" > "$stored_upstream_file"
fi

# Values are read from the source directory; the copy below is for the
# running stack, so a render-only run leaves the deployment untouched.

# The published connection endpoints: YAML lists, one entry per watcher;
# both clients take each whole list comma-joined.
p2p_list(){
  awk -v key="$1:" '
    $1 == key { inlist = 1; next }
    inlist && $1 == "-" { print $2; next }
    inlist { exit }
  ' "$NETWORK_DIR/p2p.yaml" | tr -d '"' | paste -sd, -
}
[ -f "$NETWORK_DIR/p2p.yaml" ] || die "p2p.yaml is missing — the network is not publishing an endpoint; try --refresh"
EL_ENODES=$(p2p_list el_enodes)
CL_ENRS=$(p2p_list cl_boot_enrs)
: "${EL_ENODES:?p2p.yaml carries no el_enodes — try --refresh}"
: "${CL_ENRS:?p2p.yaml carries no cl_boot_enrs — try --refresh}"

# The execution image pin lives in the upstream script.
EL_IMAGE=$(grep -m1 '^EL_IMAGE=' "$upstream_script" | cut -d= -f2- || true)
: "${EL_IMAGE:?could not extract EL_IMAGE from $upstream_script}"

# Values the status script needs, derived from the network metadata.
meta_value(){ grep -m1 "^$1:" "$NETWORK_DIR/metadata.yaml" | cut -d: -f2- | tr -d '[:space:]' || true; }
CHAIN_ID=$(meta_value chainId)
NET_NAME=$(meta_value name)
BASE_DOMAIN=$(meta_value baseDomain)
: "${CHAIN_ID:?could not read chainId from metadata.yaml}"
: "${NET_NAME:?could not read name from metadata.yaml}"
: "${BASE_DOMAIN:?could not read baseDomain from metadata.yaml}"

# Render the override: image pins and command lines, peer endpoints
# substituted in. Variables are whitelisted, envsubst doesn't modify others.
export EL_IMAGE CL_IMAGE EL_ENODES CL_ENRS
# shellcheck disable=SC2016  # Linter's complaint about variables not being expanded in single quotes is irrelevant.
envsubst '${EL_IMAGE} ${CL_IMAGE} ${EL_ENODES} ${CL_ENRS}' \
  < templates/compose.override.yaml.tmpl > compose.override.yaml
note "Rendered compose.override.yaml."

if [ "$RENDER_ONLY" = 1 ]; then
  note "Render-only run: nothing else written, nothing started."
  exit 0
fi

# Copy the artifacts in: after setup, the running stack never depends on
# where the operator keeps their artifacts clone. SHA256SUMS covers every
# file, so its own hash says whether anything changed since the last run.
artifacts_sha=$(sha256sum "$NETWORK_DIR/SHA256SUMS" | cut -d' ' -f1)
stored_artifacts_file=.setup-state/artifacts.sha256
recreate=0
if [ ! -d artifacts ] || [ ! -f "$stored_artifacts_file" ] ||
   [ "$(cat "$stored_artifacts_file")" != "$artifacts_sha" ]; then
  rm -rf artifacts
  mkdir artifacts
  cp -a "$NETWORK_DIR/." artifacts/
  printf '%s\n' "$artifacts_sha" > "$stored_artifacts_file"
  # Clients read these files only at startup, and compose does not notice
  # content changes behind a bind mount, so the change has to be pushed in.
  recreate=1
fi

# Values the status script needs.
{
  printf 'OFFICIAL_RPC=https://rpc.%s.db-chain.%s\n' "$NET_NAME" "$BASE_DOMAIN"
  printf 'CHAIN_ID=%s\n' "$CHAIN_ID"
} > .setup-state/artifacts.env

# The JWT is a local secret shared by the two clients; minted once, kept.
mkdir -p secrets
if [ ! -f secrets/jwtsecret ]; then
  openssl rand -hex 32 > secrets/jwtsecret
  # Readable by all: the clients run as a non-root container user, and the
  # secret only guards the engine API, which is not reachable off this host.
  chmod 644 secrets/jwtsecret
fi

docker compose config -q || die "the rendered stack does not validate"
docker compose pull
if [ "$recreate" = 1 ]; then
  docker compose up -d --force-recreate
else
  docker compose up -d
fi

# A container that refuses its arguments dies within a second or two —
# confirm the start before calling it a success.
sleep 3
down=0
for service in execution consensus; do
  container=$(docker compose ps -q "$service")
  if [ -z "$container" ] || [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != true ]; then
    printf '%s is not running. Its last log lines:\n' "$service" >&2
    docker compose logs --tail 20 "$service" >&2 || true
    down=1
  fi
done
[ "$down" = 0 ] || die "the node did not come up — address the cause above and run this script again"

cat <<EOF

Started. To verify:
  docker compose ps                 # both services, health goes green when synced
  ./status.sh                       # chain-level view: right chain, current head
  docker compose logs -f execution  # watch the sync progress

To update later: ./setup.sh --refresh
EOF
