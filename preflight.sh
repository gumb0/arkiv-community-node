#!/usr/bin/env bash
# preflight.sh — does this machine fit a node? See usage() below.
set -euo pipefail
cd "$(dirname "$0")"

usage(){
  cat <<'EOF'
Usage: ./preflight.sh

Checks the machine before ./setup.sh: the architecture, the commands the
scripts use, the memory and disk Docker has, the clock, and the local
ports the stack publishes. One line per check, with what to do when it
is not fine. Nothing is changed.

Exit code: 0 = nothing blocks setup (warnings may remain), 1 = something
does.
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0;;
  *) usage >&2; printf 'preflight.sh: unexpected argument: %s\n' "$1" >&2; exit 2;;
esac

# What a node needs, as floors the lines judge against. The chain state
# grows with the bytes written to the chain, tens of GB a day on a busy
# network, so the disk floor is the restored state plus a short run, and
# the warning line is the size to plan for.
MIN_MEMORY_GB=4
GOOD_MEMORY_GB=8
MIN_DISK_GB=250
GOOD_DISK_GB=1000

red='' yellow='' reset=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  red=$'\e[31m' yellow=$'\e[33m' reset=$'\e[0m'
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*) g_ok='✓' g_warn='!' g_fail='✗';;
  *)              g_ok='+' g_warn='!' g_fail='x';;
esac

failures=0
ok(){   printf '%s %-13s %s\n' "$g_ok" "$1" "$2"; }
warn(){ printf '%s%s %-13s %s%s\n' "$yellow" "$g_warn" "$1" "$2" "$reset"; }
fail(){ printf '%s%s %-13s %s%s\n' "$red" "$g_fail" "$1" "$2" "$reset"; failures=$((failures + 1)); }
hint(){ printf '              %s\n' "$1"; }

# Architecture: the official images exist for these two.
arch=$(uname -m)
case "$arch" in
  x86_64|amd64|aarch64|arm64) ok "architecture:" "$arch";;
  *) fail "architecture:" "$arch — the node images are built for x86_64 and arm64 only";;
esac

# Commands, with the same install hints setup.sh gives.
missing=0
need(){
  command -v "$1" >/dev/null && return 0
  fail "command:" "$1 is not installed — $2"
  missing=1
}
need docker "see https://docs.docker.com/engine/install/"
need git "Debian/Ubuntu: apt install git"
need openssl "Debian/Ubuntu: apt install openssl"
need envsubst "Debian/Ubuntu: apt install gettext-base"
need curl "Debian/Ubuntu: apt install curl"
[ "$missing" = 0 ] && ok "commands:" "docker, git, openssl, envsubst, curl"

# The daemon: every check below asks it. A user outside the docker group
# gets a permission error here, which reads the same as a stopped daemon.
docker_ok=0
if command -v docker >/dev/null; then
  if docker info >/dev/null 2>&1; then
    docker_ok=1
    if docker compose version >/dev/null 2>&1; then
      ok "docker:" "daemon answering, compose plugin present"
    else
      fail "docker:" "the compose plugin is not installed — Debian/Ubuntu: apt install docker-compose-v2"
    fi
  else
    fail "docker:" "the daemon does not answer — is it running, and is your user in the docker group?"
    hint "sudo systemctl start docker; sudo usermod -aG docker \$USER (then log in again)"
  fi
fi

# Memory, as Docker sees it. On a Linux host with Docker Engine that is
# the host's memory; a daemon reporting much less than the host runs the
# containers in a VM (Docker Desktop), which this stack is not made for.
if [ "$docker_ok" = 1 ]; then
  docker_mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
  host_mem_gb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  if [ "$docker_mem_gb" -lt "$MIN_MEMORY_GB" ]; then
    fail "memory:" "$docker_mem_gb GB available to Docker — the execution client needs at least $MIN_MEMORY_GB GB to sync, $GOOD_MEMORY_GB GB to run comfortably"
  elif [ "$docker_mem_gb" -lt "$GOOD_MEMORY_GB" ]; then
    warn "memory:" "$docker_mem_gb GB available to Docker — enough to follow the chain; $GOOD_MEMORY_GB GB or more is comfortable, and a swap file helps a sync from genesis"
  else
    ok "memory:" "$docker_mem_gb GB available to Docker"
  fi
  if [ "$docker_mem_gb" -lt $(( host_mem_gb * 3 / 4 )) ]; then
    warn "docker vm:" "Docker has $docker_mem_gb GB of the host's $host_mem_gb GB: it runs the containers in a VM (Docker Desktop?)"
    hint "the node is made for a Linux host with Docker Engine; a VM is not tested"
  fi
fi

# Disk: the filesystem under Docker's data root is where the volumes
# live and grow. The device behind it tells rotational from solid state.
if [ "$docker_ok" = 1 ]; then
  data_root=$(docker info --format '{{.DockerRootDir}}')
  read -r device avail_gb <<<"$(df --output=source,avail --block-size=1G "$data_root" | tail -1)"
  if [ "$avail_gb" -lt "$MIN_DISK_GB" ]; then
    fail "disk:" "$avail_gb GB free under $data_root — the restored chain state alone is larger"
    hint "the state grows by tens of GB a day; plan for $GOOD_DISK_GB GB, or point Docker's data root at a bigger disk (README)"
  elif [ "$avail_gb" -lt "$GOOD_DISK_GB" ]; then
    warn "disk:" "$avail_gb GB free under $data_root — the chain state grows by tens of GB a day; plan for $GOOD_DISK_GB GB with a way to add more"
  else
    ok "disk:" "$avail_gb GB free under $data_root"
  fi
  case "$device" in
    /dev/*)
      rota=$(lsblk -dno ROTA "$device" 2>/dev/null | tr -d '[:space:]' || true)
      case "$rota" in
        1) warn "disk type:" "$device is a rotational disk — the restore takes hours and the sync may not keep up; use an SSD or NVMe";;
        0) ok "disk type:" "$device is solid state";;
      esac;;
  esac
fi

# The clock: consensus is slot-timed, a drifting clock falls out of sync.
if command -v timedatectl >/dev/null; then
  case "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" in
    yes) ok "clock:" "NTP synchronized";;
    no)  warn "clock:" "not NTP synchronized — the consensus client needs an accurate clock"
         hint "sudo timedatectl set-ntp true";;
    *)   warn "clock:" "cannot tell whether the clock is NTP synchronized (timedatectl gave no answer)";;
  esac
else
  warn "clock:" "cannot tell whether the clock is NTP synchronized (no timedatectl)"
fi

# The local ports the stack publishes on loopback, as .env sets them.
# A running stack of our own holds them legitimately, so the check is
# for a machine where the stack is not up.
env_value(){ if [ -f .env ]; then sed -n "s/^$1=//p" .env | tail -1; fi; }
if [ "$docker_ok" = 1 ] && [ -n "$(docker compose ps -q 2>/dev/null)" ]; then
  printf '  %-13s %s\n' "ports:" "the stack is running, not checked"
else
  ports="EL_RPC_PORT=$(env_value EL_RPC_PORT) CL_HTTP_PORT=$(env_value CL_HTTP_PORT)"
  profiles=$(env_value COMPOSE_PROFILES)
  case ",$profiles," in *,tunnel,*) ports="$ports TUNNEL_STATUS_PORT=$(env_value TUNNEL_STATUS_PORT)";; esac
  case ",$profiles," in *,monitor,*) ports="$ports MONITOR_UI_PORT=$(env_value MONITOR_UI_PORT)";; esac
  taken=0
  for entry in $ports; do
    name=${entry%%=*}
    port=${entry#*=}
    case "$name" in
      EL_RPC_PORT) port=${port:-8545};;
      CL_HTTP_PORT) port=${port:-5052};;
      TUNNEL_STATUS_PORT) port=${port:-7400};;
      MONITOR_UI_PORT) port=${port:-3001};;
    esac
    if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
      fail "port:" "$port is in use — set $name in .env to a free port, or stop what listens on it"
      taken=1
    fi
  done
  [ "$taken" = 0 ] && ok "ports:" "free"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%s%s check(s) block setup%s\n' "$red" "$failures" "$reset"
  exit 1
fi
printf '\nnothing blocks setup\n'
