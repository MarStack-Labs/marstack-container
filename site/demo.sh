#!/usr/bin/env bash
set -uo pipefail

export TERM="${TERM:-xterm-256color}"
PROMPT="${PROMPT:-\$ }"
SPEED="${SPEED:-0.035}"
PAUSE="${PAUSE:-1.4}"

type_out() {
  local text="$1" i
  printf '%s' "$PROMPT"
  for ((i = 0; i < ${#text}; i++)); do
    printf '%s' "${text:i:1}"
    sleep "$SPEED"
  done
  printf '\n'
}

say() {
  type_out "$*"
  sleep 0.4
  eval "$*"
  printf '\n'
  sleep "$PAUSE"
}

command -v docker >/dev/null || { echo "docker is not installed" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "cannot reach the docker daemon" >&2; exit 1; }
docker info 2>/dev/null | grep -q ' mars' || {
  echo "mars is not registered as a docker runtime; run scripts/install-docker-runtime.sh" >&2
  exit 1
}

docker image inspect alpine:3.20 >/dev/null 2>&1 || docker pull alpine:3.20 >/dev/null 2>&1

clear

say "docker info | grep -i 'runtimes:'"

say "docker run --rm --runtime=mars alpine:3.20 echo 'this container was created by mars'"

say "docker run --rm --runtime=mars --memory=64m alpine:3.20 cat /sys/fs/cgroup/memory.max"

say "docker run --rm --runtime=mars alpine:3.20 ps -o pid,comm"

say "docker run --rm --runtime=mars alpine:3.20 readlink /proc/self/ns/pid"

say "readlink /proc/self/ns/pid"

say "docker run --rm --runtime=mars alpine:3.20 cat /proc/self/status | grep -E 'CapEff|CapBnd'"

sleep 2
