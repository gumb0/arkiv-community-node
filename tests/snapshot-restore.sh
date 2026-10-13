#!/usr/bin/env bash
# The snapshot restore over a fixture: a tiny snapshot served from this
# host, restored into throwaway volumes, then refused for a wrong hash
# and for a tombstone. Part of the gate (tests/ci.sh); needs docker.
set -euo pipefail
cd "$(dirname "$0")/.."

note(){ printf '== %s\n' "$*"; }
port=18099
work=$(mktemp -d)
export COMPOSE_PROJECT_NAME=snapshot-test COMPOSE_PROGRESS=quiet
export ARTIFACTS_DIR=$PWD/tests/fixture-network SETUP_STATE_DIR=$work/state
export NET_NAME=fixture SNAPSHOTS_URL=http://host.docker.internal:$port
EL_IMAGE=$(grep -m1 '^EL_IMAGE=' tests/fixture-network/run-node.sh | cut -d= -f2-)
CL_IMAGE=$(grep -m1 '^CL_IMAGE=' tests/fixture-network/run-node.sh | cut -d= -f2-)
export EL_IMAGE CL_IMAGE
mkdir -p "$work/state"

cleanup(){
  [ -z "${server:-}" ] || kill "$server" 2>/dev/null || true
  docker volume rm -f snapshot-test_el-data snapshot-test_cl-data >/dev/null 2>&1 || true
  docker network rm snapshot-test_default >/dev/null 2>&1 || true
  # The image is built under this project's name; its layers stay
  # cached, so the next run rebuilds it in seconds.
  docker image rm -f snapshot-test-snapshot >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# The fixture: two layers of one file each, and the manifest that
# describes them the way the network's endpoint does.
layer(){ # layer <name> <content> — writes <name>.tar.gz, prints "<bytes> <sha256>"
  local dir="$work/raw/$1" archive="$work/serve/fixture/run1/$1.tar.gz" bytes sha
  mkdir -p "$dir/db"
  printf '%s\n' "$2" > "$dir/db/marker"
  tar -czf "$archive" -C "$dir" db
  # The two figures the manifest has to carry for the restore's checks.
  bytes=$(stat -c %s "$archive")
  sha=$(sha256sum "$archive" | cut -d' ' -f1)
  printf '%s %s\n' "$bytes" "$sha"
}
# The sizes come from the globals the read lines below set; only the
# hashes are arguments, since they are what the second scenario changes.
manifest(){ # manifest <el sha> <cl sha>
  cat > "$work/serve/fixture/latest.json" <<JSON
{
  "network": "fixture", "chainId": 999999, "genesisTime": 1700000000,
  "run": "run1", "head": { "slot": 10, "block": 9 },
  "images": { "reth": "$EL_IMAGE", "lighthouse": "$CL_IMAGE" },
  "layers": {
    "el": { "key": "fixture/run1/el.tar.gz", "rawBytes": 4096, "bytes": $el_bytes, "sha256": "$1" },
    "cl": { "key": "fixture/run1/cl.tar.gz", "rawBytes": 4096, "bytes": $cl_bytes, "sha256": "$2" }
  }
}
JSON
}
mkdir -p "$work/serve/fixture/run1"
read -r el_bytes el_sha < <(layer el "execution chain data")
read -r cl_bytes cl_sha < <(layer cl "consensus chain data")
manifest "$el_sha" "$cl_sha"

python3 -m http.server "$port" --bind 0.0.0.0 --directory "$work/serve" >/dev/null 2>&1 &
server=$!
# Up to ten seconds for the server to answer, rather than a fixed wait
# a slow runner outlasts.
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$port/fixture/latest.json" >/dev/null && break
  sleep 0.5
done

restore(){ docker compose --profile snapshot run --rm --no-deps snapshot; }
in_volume(){ # in_volume <el|cl|state> <sh command> — run in the container, in that mount
  docker compose --profile snapshot run --rm --no-deps --entrypoint sh snapshot -c "cd /$1 && $2"
}

note "a snapshot is restored into both volumes, and the manifest kept"
docker compose --profile snapshot build -q snapshot
restore
[ "$(in_volume el 'cat db/marker')" = "execution chain data" ]
[ "$(in_volume cl 'cat db/marker')" = "consensus chain data" ]
[ "$(in_volume state 'jq -r .run snapshot.json')" = run1 ]

note "a layer whose hash disagrees with the manifest is refused, and both volumes emptied"
docker volume rm -f snapshot-test_el-data snapshot-test_cl-data >/dev/null
manifest "$el_sha" "0000000000000000000000000000000000000000000000000000000000000000"
if restore 2>/dev/null; then echo "a wrong hash was accepted" >&2; exit 1; fi
[ -z "$(in_volume el 'ls -A')" ] && [ -z "$(in_volume cl 'ls -A')" ]

note "a layer that is not an archive fails after the other landed; both volumes emptied"
docker volume rm -f snapshot-test_el-data snapshot-test_cl-data >/dev/null
printf 'not a gzip\n' > "$work/serve/fixture/run1/cl.tar.gz"
cl_bytes=$(stat -c %s "$work/serve/fixture/run1/cl.tar.gz")
manifest "$el_sha" "$(sha256sum "$work/serve/fixture/run1/cl.tar.gz" | cut -d' ' -f1)"
if restore 2>/dev/null; then echo "a broken archive was accepted" >&2; exit 1; fi
[ -z "$(in_volume el 'ls -A')" ] && [ -z "$(in_volume cl 'ls -A')" ]

note "a tombstone is 'nothing to restore', exit 3"
printf '%s\n' '{ "network": "fixture", "wiped": "2026-10-01T10:08:00Z" }' > "$work/serve/fixture/latest.json"
set +e; restore 2>/dev/null; rc=$?; set -e
[ "$rc" = 3 ] || { echo "a tombstone exited $rc, not 3" >&2; exit 1; }
