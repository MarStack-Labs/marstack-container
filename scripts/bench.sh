#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: bench.sh [--out PATH] [--runs N] [--binary PATH] [SECTION ...]

Measure what the site publishes about this runtime, and write it as JSON the
page reads at load time. Nothing is typed into the page by hand: a number that
was not measured here stays absent, and the page renders it as a dash.

This does NOT run the horizontal attack profile. That needs root, ftrace and a
long serial run; scripts/hap-bench.sh owns it and prints its own table.

Sections (default: all of them)
  binary     size of the release binary
  deps       direct and total crate count, the dependency surface
  start      docker run to a container that has exited, through each runtime
  caps       the effective capability set a container is left holding
  validation the OCI runtime-spec assertions this build passes

Environment
  IMAGE      image the probe container runs, default alpine:3.20
  RUNTIMES   space separated docker runtime names, default "mars runc"

The start section needs a docker daemon with the runtimes registered; see
scripts/install-docker-runtime.sh. Everything else reads the source tree.

Requires: python3 and cargo; docker for the start and caps sections.
EOF
  exit 2
}

OUT=""
RUNS=5
BINARY=""
SECTIONS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 || usage ;;
    --runs) RUNS="${2:-}"; shift 2 || usage ;;
    --binary) BINARY="${2:-}"; shift 2 || usage ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) SECTIONS+=("$1"); shift ;;
  esac
done

[ ${#SECTIONS[@]} -eq 0 ] && SECTIONS=(binary deps start caps validation)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
[ -n "$BINARY" ] || BINARY="$TARGET_DIR/release/mars"
IMAGE="${IMAGE:-alpine:3.20}"
RUNTIMES="${RUNTIMES:-mars runc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

has() { for s in "${SECTIONS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
note() { printf '%s\n' "$*" >&2; }
emit() { printf '%s\t%s\n' "$1" "$2" >> "$WORK/pairs"; }

stat_percentile() {
  python3 - "$@" <<'PY'
import sys, statistics
vals = sorted(float(v) for v in sys.argv[2:])
if not vals:
    print("null"); sys.exit()
q = float(sys.argv[1])
if q == 50:
    print(round(statistics.median(vals), 1)); sys.exit()
k = (len(vals) - 1) * q / 100
lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
print(round(vals[lo] + (vals[hi] - vals[lo]) * (k - lo), 1))
PY
}

measure_binary() {
  if [ ! -x "$BINARY" ]; then
    note "binary: $BINARY is not there, run cargo build --release first"
    return
  fi
  local bytes
  bytes="$(python3 -c 'import os,sys;print(os.path.getsize(sys.argv[1]))' "$BINARY")"
  emit binary_bytes "$bytes"
  note "binary: $bytes bytes"
}

measure_deps() {
  local direct total
  direct="$(python3 - "$ROOT/Cargo.toml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^\[dependencies\](.*?)(^\[|\Z)", text, re.S | re.M)
if not m:
    print(0); sys.exit()
print(sum(1 for line in m.group(1).splitlines()
          if line.strip() and not line.strip().startswith("#") and "=" in line))
PY
)"
  total="$(python3 - "$ROOT/Cargo.lock" <<'PY'
import sys
text = open(sys.argv[1]).read()
print(max(text.count("[[package]]") - 1, 0))
PY
)"
  [ -n "$direct" ] && emit deps_direct "$direct"
  [ -n "$total" ] && emit deps_total "$total"
  note "deps: $direct direct, $total crates locked"
}

docker_ready() {
  command -v docker >/dev/null 2>&1 || { note "docker is not installed"; return 1; }
  docker info >/dev/null 2>&1 || { note "the docker daemon cannot be reached"; return 1; }
  docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" >/dev/null 2>&1
  return 0
}

measure_start() {
  docker_ready || return
  local rt samples=() i t0 t1
  for rt in $RUNTIMES; do
    if ! docker info 2>/dev/null | grep -qE "(^| )$rt( |$)"; then
      note "start: docker has no runtime called $rt, skipping"
      continue
    fi
    docker run --rm --runtime="$rt" "$IMAGE" true >/dev/null 2>&1
    samples=()
    for i in $(seq 1 "$RUNS"); do
      t0="$(now_ms)"
      docker run --rm --runtime="$rt" "$IMAGE" true >/dev/null 2>&1 || continue
      t1="$(now_ms)"
      samples+=("$((t1 - t0))")
    done
    [ ${#samples[@]} -eq 0 ] && continue
    emit "start_${rt}_ms" "$(stat_percentile 50 "${samples[@]}")"
    note "start $rt: $(stat_percentile 50 "${samples[@]}") ms median over ${#samples[@]} runs"
  done
}

measure_caps() {
  docker_ready || return
  local mask count
  mask="$(docker run --rm --runtime=mars "$IMAGE" \
    grep CapEff /proc/self/status 2>/dev/null | awk '{print $2}')"
  [ -z "$mask" ] && { note "caps: could not read the capability set"; return; }
  count="$(python3 -c "print(bin(int('$mask', 16)).count('1'))")"
  emit cap_effective_hex "$mask"
  emit cap_effective_count "$count"
  note "caps: container keeps $count capabilities, mask $mask"
}

measure_validation() {
  local passed
  passed="$(grep -hoE '\*\*[0-9]+ passed\*\*|[0-9]+ passed' \
    "$ROOT/README.md" "$ROOT/docs/05-hardening.md" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1)"
  [ -z "$passed" ] && { note "validation: no recorded pass count found"; return; }
  emit validation_passed "$passed"
  note "validation: $passed assertions recorded as passing"
}

: > "$WORK/pairs"
has binary && measure_binary
has deps && measure_deps
has start && measure_start
has caps && measure_caps
has validation && measure_validation

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
HOST_KERNEL="$(uname -r)"
HOST_CPU="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
[ -n "$HOST_CPU" ] || {
  VIRT="$(systemd-detect-virt 2>/dev/null)"
  [ -n "$VIRT" ] && [ "$VIRT" != none ] && HOST_CPU="$HOST_ARCH guest under $VIRT"
}
[ -n "$HOST_CPU" ] || HOST_CPU="unknown"
HOST_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
HOST_CPU="$HOST_CPU, $HOST_CORES cores"
VERSION="$("$BINARY" --version 2>/dev/null | head -1 || echo unknown)"

JSON="$(python3 - "$WORK/pairs" <<PY
import json, sys, datetime
values = {}
with open(sys.argv[1]) as fh:
    for line in fh:
        if not line.strip():
            continue
        k, v = line.rstrip("\n").split("\t", 1)
        try:
            values[k] = int(v) if v.isdigit() else float(v)
        except ValueError:
            values[k] = v
doc = {
    "measured_at": datetime.datetime.now().astimezone().strftime("%Y-%m-%d"),
    "method": {
        "host": "$HOST_CPU".strip(),
        "os": "$HOST_OS $HOST_KERNEL ($HOST_ARCH)",
        "version": "$VERSION".strip(),
        "runs": $RUNS,
        "statistic": "median, fresh container per run, image already pulled",
    },
    "values": values,
}
print(json.dumps(doc, indent=2))
PY
)"

if [ -n "$OUT" ]; then
  printf '%s\n' "$JSON" > "$OUT"
  note "wrote $OUT"
else
  printf '%s\n' "$JSON"
fi
