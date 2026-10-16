#!/usr/bin/env bash
# Whether the network operator's run-node.sh is the version this
# stack's translation (compose.override.yaml.tmpl, snapshot/restore.sh)
# was reviewed against. The lines that differ per network — the chain's
# name, its snapshots endpoint, the two image pins — are left out of
# the hash, so one recorded hash covers every network the operator
# publishes from the same script.
#
#   tests/upstream-drift.sh <run-node.sh>
#       compares the script with the record: exit code 0 when it is the
#       reviewed version, 1 when it changed since
#   tests/upstream-drift.sh --record <run-node.sh> <commit>
#       records the script as reviewed, naming the artifacts repository's
#       commit the review was of
set -euo pipefail
cd "$(dirname "$0")/.."
record=${DRIFT_RECORD:-tests/upstream-run-node.sha256}

digest(){ # digest <run-node.sh> — the hash with the per-network lines left out
  sed -E -e '/^NETWORK=/d' -e '/^SNAPSHOTS_URL=/d' -e '/^EL_IMAGE=/d' -e '/^CL_IMAGE=/d' \
    -e 's/^(# run-node\.sh — bring up a node that follows the ).* chain\./\1chain./' "$1" \
    | sha256sum | cut -d' ' -f1
}

case "${1:-}" in
  --record)
    if [ ! -f "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "usage: $0 --record <run-node.sh> <commit>" >&2
      exit 2
    fi
    printf '%s %s\n' "$(digest "$2")" "$3" > "$record"
    echo "recorded $2 as reviewed, at db-chain-networks $3"
    exit 0;;
  "" | -h | --help)
    sed -n '2,14p' "$0" | sed 's/^# \?//' >&2
    exit 2;;
esac

[ -f "$1" ] || { echo "$1: no such file" >&2; exit 2; }
read -r want commit < "$record"
if [ "$(digest "$1")" = "$want" ]; then
  echo "upstream run-node.sh is the reviewed version (db-chain-networks $commit)"
  exit 0
fi
cat >&2 <<EOF
the upstream run-node.sh changed since the translation was reviewed against db-chain-networks $commit.
Review its diff for what the stack and the snapshot restore translate, adapt
templates/compose.override.yaml.tmpl and snapshot/restore.sh, then record the review:
  tests/upstream-drift.sh --record $1 <commit>
EOF
exit 1
