#!/usr/bin/env bash
# Fills the two chain volumes from the network's published snapshot, so
# a node starts near the head instead of syncing from genesis. Runs in
# the snapshot container (compose service "snapshot"), which mounts the
# execution datadir at /el, the consensus datadir at /cl, the network
# artifacts at /gen and the setup state at /state. setup.sh runs it
# when both datadirs are empty.
#
# A translation of the bootstrap step in the network's own run-node.sh:
# the manifest, its checks, and the ranged, verified fetch of each layer
# are the same. Three of its features are left out, since no network we
# serve has them yet: restoring from a directory of pre-downloaded
# files (SNAPSHOT_DIR), private snapshots that need such a directory,
# and a seeded genesis (initial-snapshot.json), which is refused below
# rather than ignored.
#
# Exit codes: 0 restored; 3 no snapshot to restore (the network has none,
# or was wiped since its last one), both datadirs left empty; 1 failed,
# both datadirs emptied so a re-run starts clean.
set -euo pipefail

: "${NETWORK:?the network name}"
: "${SNAPSHOTS_URL:?the snapshots endpoint}"
: "${EL_IMAGE:?the execution image the node runs}"
: "${CL_IMAGE:?the consensus image the node runs}"

say(){ echo "$(date -u +%FT%TZ) restore: $*" >&2; }

# Anything that goes wrong leaves both datadirs empty: a re-run then
# starts clean instead of resuming onto half a chain.
cleanup(){
  if [ "$1" -eq 1 ] && { [ -n "$(ls -A /el)" ] || [ -n "$(ls -A /cl)" ]; }; then
    say "failed — emptying both datadirs so a re-run starts clean"
    find /el /cl -mindepth 1 -delete
  fi
}
trap 'cleanup $?' EXIT

# A network whose execution genesis is seeded state ships an
# initial-snapshot.json and cannot sync from genesis at all. This
# script does not restore one yet, and says so rather than starting a
# sync that can never finish.
if [ -s /gen/initial-snapshot.json ]; then
  say "this network ships an initial snapshot (seeded genesis state), which this tooling does not support yet — please open an issue"
  exit 1
fi

# The manifest: 200 with the layers, 404 when the network publishes
# none, or 200 with a "wiped" field when the network was wiped since
# its last snapshot (the tombstone). The last two are not failures:
# the node syncs from genesis instead, and setup.sh says so.
manifest=/tmp/latest.json
code=$(curl -sS -o "$manifest" -w '%{http_code}' "$SNAPSHOTS_URL/$NETWORK/latest.json") \
  || { say "cannot reach $SNAPSHOTS_URL"; exit 1; }
case "$code" in
  200)
    if jq -e '.wiped' "$manifest" >/dev/null 2>&1; then
      say "$NETWORK was wiped at $(jq -r '.wiped' "$manifest") and has published no snapshot since"
      exit 3
    fi;;
  404) say "no snapshot is published for $NETWORK at $SNAPSHOTS_URL"; exit 3;;
  *)   say "GET $SNAPSHOTS_URL/$NETWORK/latest.json: HTTP $code"; exit 1;;
esac

# A snapshot of another chain is refused, and so is one of another
# life of this chain: a wipe keeps the chain id and restamps
# MIN_GENESIS_TIME in config.yaml, so a manifest recording another
# genesis time is of a chain that is not the one in the artifacts.
# Which side is behind says what to do: a newer snapshot means the
# artifacts are stale, an older one that the network has published
# none since its wipe.
want=$(jq -r .config.chainId /gen/genesis.json)
have=$(jq -r .chainId "$manifest")
if [ "$want" != "$have" ]; then
  say "the snapshot is of chain $have and this network is chain $want — refusing it"
  exit 1
fi
have=$(jq -r '.genesisTime // empty' "$manifest")
if [ -n "$have" ]; then
  want=$(sed -n 's/^MIN_GENESIS_TIME:[[:space:]]*//p' /gen/config.yaml 2>/dev/null | tr -d "\"' \r")
  if [ "$want" != "$have" ]; then
    if [ -n "$want" ] && [ "$have" -gt "$want" ] 2>/dev/null; then
      say "the snapshot is of a later life of $NETWORK than these artifacts (genesis time $have against $want): the artifacts are stale — run ./setup.sh --refresh"
    else
      say "the snapshot is of an earlier life of $NETWORK (genesis time $have, this network's ${want:-unknown}): the network has published none since its wipe — refusing it"
    fi
    exit 1
  fi
fi

# The images that wrote the snapshot against the ones this node runs:
# a difference to know about, not a reason to stop. Two references
# naming one digest are the same image however the repository is spelt.
digest(){ case "$1" in *@sha256:*) echo "${1##*@}";; *) echo "$1";; esac; }
for pair in "reth:$EL_IMAGE" "lighthouse:$CL_IMAGE"; do
  layer=${pair%%:*}   # before the first colon; the reference has colons of its own
  ours=${pair#*:}
  theirs=$(jq -r ".images.$layer" "$manifest")
  [ "$(digest "$ours")" = "$(digest "$theirs")" ] \
    || say "note: the snapshot was written by $theirs, and this node runs $ours"
done

# Free space against both layers unpacked, plus a tenth for the chain
# to grow into while the node catches up.
raw=$(jq -r '.layers.el.rawBytes + (.layers.cl.rawBytes // 0)' "$manifest")
gz=$(jq -r '.layers.el.bytes + (.layers.cl.bytes // 0)' "$manifest")
avail=$(df -kP /el | awk 'NR==2{print $4*1024}')
need=$((raw + raw / 10))
say "$((gz/1024/1024/1024)) GiB to fetch, $((raw/1024/1024/1024)) GiB unpacked, $((avail/1024/1024/1024)) GiB free"
if [ "$avail" -lt "$need" ]; then
  say "not enough free space: the restore needs $((need/1024/1024/1024)) GiB with headroom"
  exit 1
fi

# One range of an object, retried until it arrives whole. A stream held
# open for a whole layer is reset partway through, and a range that
# comes up short is a truncated chunk; a transfer under the floor for
# a minute is a connection worth replacing. Each wait is a little
# longer than the last.
fetch_range(){
  local url=$1 from=$2 to=$3 out=$4 floor=$5 backoff=${RETRY_BACKOFF:-5} n try
  n=$((to - from + 1))
  for try in 1 2 3 4 5 6; do
    if curl -fsS -r "$from-$to" --connect-timeout 30 --speed-limit "$floor" --speed-time 60 -o "$out" "$url" \
      && [ "$(stat -c %s "$out")" -eq "$n" ]; then
      return 0
    fi
    rm -f "$out"
    [ "$try" -lt 6 ] || { say "range $from-$to of ${url##*/} did not arrive whole in $try tries"; return 1; }
    sleep $((try * backoff))
  done
}

# The floor a range has to hold: an eighth of the fastest range so far,
# never under a megabyte a second, so a connection crawling where
# others flew is replaced and one that is simply slow is left to run.
floor_for(){
  local min=${MIN_RATE:-1048576} eighth=$(($1 / 8))
  echo $((eighth > min ? eighth : min))
}

# An object streamed to stdout a range at a time, the next range
# downloading while the current one is written into the pipe: the
# unpack is the slower half, so the fetch costs no time of its own.
# Two chunk files exist at once, 2 GiB of /tmp by default.
fetch_object(){
  local url=$1 total=$2 chunk=${CHUNK_BYTES:-$((1<<30))} from=0 to slot=0 cur next pid
  local best=0 flight=0 started=0 rate
  [ "$total" -gt 0 ] || return 0
  to=$((chunk - 1))
  [ "$to" -ge "$total" ] && to=$((total - 1))
  cur=/tmp/chunk.$slot
  flight=$((to - from + 1))
  started=$SECONDS
  fetch_range "$url" "$from" "$to" "$cur" "$(floor_for "$best")" || return 1
  rate=$((flight / (SECONDS - started + 1)))
  [ "$rate" -gt "$best" ] && best=$rate
  while :; do
    from=$((to + 1))
    pid=""
    if [ "$from" -lt "$total" ]; then
      to=$((from + chunk - 1))
      [ "$to" -ge "$total" ] && to=$((total - 1))
      slot=$((1 - slot))
      next=/tmp/chunk.$slot
      flight=$((to - from + 1))
      started=$SECONDS
      fetch_range "$url" "$from" "$to" "$next" "$(floor_for "$best")" &
      pid=$!
    fi
    cat "$cur"
    rm -f "$cur"
    [ -n "$pid" ] || break
    # A range that spent its tries fails the layer rather than reaching
    # tar as a hole.
    wait "$pid" || return 1
    rate=$((flight / (SECONDS - started + 1)))
    [ "$rate" -gt "$best" ] && best=$rate
    cur=$next
  done
  rm -f /tmp/chunk.0 /tmp/chunk.1
}

# One layer unpacked into its datadir, hashed and counted on the way
# into tar, so a download that arrived wrong is caught rather than
# started from. The hashes come from the host that serves the data:
# they catch transfer damage, nothing else.
restore_layer(){
  local layer=$1 dir=$2 key want_sha want_bytes have_sha have_bytes started first
  key=$(jq -r ".layers.$layer.key" "$manifest")
  want_sha=$(jq -r ".layers.$layer.sha256" "$manifest")
  want_bytes=$(jq -r ".layers.$layer.bytes" "$manifest")
  rm -f "/tmp/$layer.sha" "/tmp/$layer.bytes"
  started=$(date +%s)
  say "$layer: fetching $key"
  fetch_object "$SNAPSHOTS_URL/$key" "$want_bytes" \
    | tee >(sha256sum | cut -d' ' -f1 > "/tmp/$layer.sha") >(wc -c | tr -d ' ' > "/tmp/$layer.bytes") \
    | tar -xzf - -C "$dir"
  # The two readers hang off the pipeline and finish just after it.
  for _ in $(seq 1 30); do
    [ -s "/tmp/$layer.sha" ] && [ -s "/tmp/$layer.bytes" ] && break
    sleep 1
  done
  have_sha=$(cat "/tmp/$layer.sha")
  have_bytes=$(cat "/tmp/$layer.bytes")
  if [ "$have_sha" != "$want_sha" ]; then
    say "$layer: sha256 mismatch — $have_sha arrived, the manifest says $want_sha"
    exit 1
  fi
  if [ "$have_bytes" != "$want_bytes" ]; then
    say "$layer: size mismatch — $have_bytes bytes arrived, the manifest says $want_bytes"
    exit 1
  fi
  # The archive records the datadir's root as root-owned with the
  # client's group: the root takes the ownership of what it holds, so
  # the client can write in it.
  first=$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)
  chown "$(stat -c %u:%g "$first")" "$dir"
  say "$layer: verified $have_bytes bytes in $(($(date +%s) - started)) s"
}

run=$(jq -r .run "$manifest")
block=$(jq -r .head.block "$manifest")
say "snapshot $run: block $block"
restore_layer el /el
restore_layer cl /cl
# The manifest is kept for status.sh to say where the node started.
cp "$manifest" /state/snapshot.json
say "restored $NETWORK at block $block from snapshot $run — the node syncs forward from there"
