#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: hap-bench.sh [WORKLOAD ...]

Measure the horizontal attack profile of the container creation path: how many
distinct host kernel functions a runtime traverses while it holds root, for one
container carrying a minimal static C program.

Workloads (default: all four)
  run    foreground run to container exit
  vol    same, with a read-only bind mount
  exec   exec into an already-running container
  tty    detached run with a pty handed over a console socket

Environment
  RUNTIMES  space separated NAME=PATH pairs
            (default: "runc=runc crun=crun mars=mars")
  RUNS      traced repetitions per cell (default: 5)
  OUT       working directory (default: /tmp/hap-bench)
  BUF       trace-cmd ring buffer, KB per CPU (default: 60000)
  PROFILE   seccomp profile URL to adapt
            (default: the containers/common profile Podman and CRI-O ship)

Requires root, and: gcc jq curl python3 trace-cmd runc.
EOF
  exit 2
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

RUNTIMES="${RUNTIMES:-runc=runc crun=crun mars=mars}"
RUNS="${RUNS:-5}"
OUT="${OUT:-/tmp/hap-bench}"
BUF="${BUF:-60000}"
PROFILE="${PROFILE:-https://raw.githubusercontent.com/containers/common/main/pkg/seccomp/seccomp.json}"
WORKLOADS=("$@")
[[ ${#WORKLOADS[@]} -eq 0 ]] && WORKLOADS=(run vol exec tty)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECVTTY="$REPO_ROOT/tests/recvtty.py"

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "this measures Linux kernel functions; run it in a Linux VM"
[[ "$EUID" -eq 0 ]] || die "tracing and container creation need root; use sudo -E"
for t in gcc jq curl python3 trace-cmd runc; do
  command -v "$t" >/dev/null || die "$t is not on PATH"
done
[[ -r /sys/kernel/tracing/available_tracers ]] ||
  die "ftrace is not exposed at /sys/kernel/tracing"
grep -qw function /sys/kernel/tracing/available_tracers ||
  die "the kernel has no function tracer; CONFIG_FUNCTION_TRACER is off"
[[ -r "$RECVTTY" ]] || die "$RECVTTY not found"

rm -rf "$OUT"; mkdir -p "$OUT"

declare -a RT_NAMES RT_BINS
for pair in $RUNTIMES; do
  n=${pair%%=*}; b=${pair#*=}
  command -v "$b" >/dev/null || { echo "skipping $n: $b is not on PATH" >&2; continue; }
  RT_NAMES+=("$n"); RT_BINS+=("$b")
done
[[ ${#RT_NAMES[@]} -gt 0 ]] || die "no runtime under test is installed"

build_programs() {
  printf 'int main(void){return 0;}\n' > "$OUT/app.c"
  printf '#include <unistd.h>\nint main(void){sleep(300);return 0;}\n' > "$OUT/sleeper.c"
  gcc -static -O2 -o "$OUT/app" "$OUT/app.c" || die "cannot build a static test program"
  gcc -static -O2 -o "$OUT/sleeper" "$OUT/sleeper.c" || die "cannot build the sleeper"
}

fetch_profile() {
  curl -sSL -o "$OUT/profile-src.json" "$PROFILE" || die "cannot fetch $PROFILE"
  jq -e . "$OUT/profile-src.json" >/dev/null 2>&1 ||
    die "$PROFILE did not return JSON; the upstream path may have moved"
}

adapt_profile() {
  local caps_json=$1 arch=$2 scmp_json=$3
  jq --argjson caps "$caps_json" --arg arch "$arch" --argjson scmp "$scmp_json" '
    {
      defaultAction: .defaultAction,
      architectures: $scmp,
      syscalls: [ .syscalls[]
        | select(
            ((.includes.arches // null) == null or (.includes.arches | any(. == $arch)))
            and ((.includes.caps // null) == null
                 or (.includes.caps | any(. as $c | $caps | index($c))))
            and ((.excludes.caps // null) == null
                 or ((.excludes.caps | map(. as $c | $caps | index($c))
                      | map(select(. != null)) | length) == 0))
          )
        | {names, action}
          + (if (.args // null) != null and (.args | length) > 0 then {args} else {} end)
          + (if (.errnoRet // null) != null then {errnoRet} else {} end)
      ]
    }' "$OUT/profile-src.json" > "$OUT/profile-oci.json"
}

drop_syscall() {
  jq --arg s "$1" '
    .syscalls = [ .syscalls[]
      | .names = [ .names[] | select(. != $s) ]
      | select((.names | length) > 0) ]' "$OUT/profile.json" > "$OUT/p.tmp"
  mv "$OUT/p.tmp" "$OUT/profile.json"
}

converge_profile() {
  cp "$OUT/profile-oci.json" "$OUT/profile.json"
  : > "$OUT/profile-rejections.txt"
  local i n bad
  for ((i = 0; i < ${#RT_NAMES[@]}; i++)); do
    n=${RT_NAMES[i]}
    local removed=0
    while true; do
      write_bundle "$OUT/probe" "$OUT/app" '["/app"]' false
      "${RT_BINS[i]}" delete -f "happrobe-$n" >/dev/null 2>&1
      local err; err=$("${RT_BINS[i]}" run --bundle "$OUT/probe" "happrobe-$n" 2>&1)
      local rc=$?
      "${RT_BINS[i]}" delete -f "happrobe-$n" >/dev/null 2>&1
      [[ $rc -eq 0 ]] && break
      bad=$(printf '%s' "$err" \
        | grep -oE 'seccomp rule for [a-z0-9_]+' | head -1 | awk '{print $NF}')
      [[ -z "$bad" ]] && die "$n fails on the probe bundle for a non-seccomp reason: $err"
      echo "$n $bad" >> "$OUT/profile-rejections.txt"
      drop_syscall "$bad"
      removed=$((removed + 1))
      [[ $removed -gt 200 ]] && die "$n rejected more than 200 syscalls; giving up"
    done
    echo "  $n accepts the profile after $removed removals"
  done
}

write_bundle() {
  local dir=$1 prog=$2 args=$3 terminal=$4 mount=${5:-}
  rm -rf "$dir"; mkdir -p "$dir/rootfs"
  cp "$prog" "$dir/rootfs/$(basename "$prog")"
  [[ "$prog" != "$OUT/app" ]] && cp "$OUT/app" "$dir/rootfs/app"
  ( cd "$dir" && runc spec )
  local extra='.'
  [[ -n "$mount" ]] && extra='.mounts += [{"destination":"/data","type":"bind","source":"'"$mount"'","options":["rbind","ro"]}]'
  jq --slurpfile sc "$OUT/profile.json" --argjson args "$args" --argjson tty "$terminal" "
      .ociVersion = \"1.0.2\"
      | .process.args = \$args
      | .process.terminal = \$tty
      | .root.readonly = true
      | .linux.seccomp = \$sc[0]
      | $extra" "$dir/config.json" > "$dir/c.json"
  mv "$dir/c.json" "$dir/config.json"
}

record() {
  local label=$1; shift
  trace-cmd record -p function -b "$BUF" -o "$OUT/$label.dat" "$@" \
    >"$OUT/$label.cmdout" 2>&1
  trace-cmd report -i "$OUT/$label.dat" 2>/dev/null > "$OUT/$label.rep"
  rm -f "$OUT/$label.dat"
}

attribute() {
  local label=$1 rt=$2
  : > "$OUT/$label.own"
  awk -v rt="$rt" '
    /function:/ {
      p = $1; sub(/-[0-9]+$/, "", p)
      if (p == rt || p == "app" || p == "sleeper" || index(p, rt ":") == 1)
        print $NF > OWN
    }' OWN="$OUT/$label.own" "$OUT/$label.rep"
  awk '/function:/ { p = $1; sub(/-[0-9]+$/, "", p); print p }' "$OUT/$label.rep" \
    | sort -u > "$OUT/$label.procs"
  sort -u -o "$OUT/$label.own" "$OUT/$label.own"
  rm -f "$OUT/$label.rep"
}

measure_idle() {
  local i
  for i in 1 2 3; do
    record "idle-$i" sleep 1
    awk '/function:/ {print $NF}' "$OUT/idle-$i.rep" | sort -u > "$OUT/idle-$i.funcs"
    rm -f "$OUT/idle-$i.rep"
  done
  sort -u "$OUT"/idle-*.funcs > "$OUT/idle.union"
  echo "  idle union: $(wc -l < "$OUT/idle.union") functions"
}

echo "== preparing =="
build_programs
fetch_profile
mkdir -p "$OUT/probe-spec" && ( cd "$OUT/probe-spec" && runc spec )
CAPS=$(jq -c '.process.capabilities.bounding // []' "$OUT/probe-spec/config.json")
case "$(uname -m)" in
  aarch64) ARCH=arm64; SCMP='["SCMP_ARCH_AARCH64","SCMP_ARCH_ARM"]' ;;
  x86_64)  ARCH=amd64; SCMP='["SCMP_ARCH_X86_64","SCMP_ARCH_X86","SCMP_ARCH_X32"]' ;;
  *) die "no seccomp architecture mapping for $(uname -m)" ;;
esac
adapt_profile "$CAPS" "$ARCH" "$SCMP"
echo "  profile: $(jq '[.syscalls[].names[]] | length' "$OUT/profile-oci.json") syscall names, arch $ARCH"
converge_profile
echo "  shared profile: $(jq '[.syscalls[].names[]] | length' "$OUT/profile.json") syscall names"

write_bundle "$OUT/b-run"  "$OUT/app"     '["/app"]'     false
write_bundle "$OUT/b-tty"  "$OUT/app"     '["/app"]'     true
write_bundle "$OUT/b-exec" "$OUT/sleeper" '["/sleeper"]' false
mkdir -p "$OUT/voldir" && echo present > "$OUT/voldir/marker"
write_bundle "$OUT/b-vol"  "$OUT/app"     '["/app"]'     false "$OUT/voldir"

echo "== idle baseline =="
measure_idle

echo "== measuring =="
: > "$OUT/results"
for ((i = 0; i < ${#RT_NAMES[@]}; i++)); do
  name=${RT_NAMES[i]}; bin=${RT_BINS[i]}
  for wl in "${WORKLOADS[@]}"; do
    counts=(); dropped=0
    for ((r = 1; r <= RUNS; r++)); do
      id="hap-$name-$wl-$r"; lbl="$name-$wl-$r"; need_app=1; rp=""
      "$bin" delete -f "$id" >/dev/null 2>&1
      case $wl in
        run) record "$lbl" "$bin" run --bundle "$OUT/b-run" "$id" ;;
        vol) record "$lbl" "$bin" run --bundle "$OUT/b-vol" "$id" ;;
        exec)
          "$bin" run -d --bundle "$OUT/b-exec" "$id" >/dev/null 2>&1
          sleep 1
          record "$lbl" "$bin" exec "$id" /app
          ;;
        tty)
          python3 "$RECVTTY" "$OUT/con-$name.sock" "$OUT/con-$name.out" \
            >"$OUT/con-$name.log" 2>&1 &
          rp=$!
          for _ in $(seq 1 50); do
            grep -q listening "$OUT/con-$name.log" 2>/dev/null && break
            sleep 0.1
          done
          record "$lbl" "$bin" run -d --bundle "$OUT/b-tty" \
            --console-socket "$OUT/con-$name.sock" "$id"
          need_app=0
          ;;
        *) die "unknown workload: $wl" ;;
      esac
      attribute "$lbl" "$name"
      [[ -n "$rp" ]] && kill -9 "$rp" >/dev/null 2>&1
      "$bin" delete -f "$id" >/dev/null 2>&1
      if ! grep -qx "$name" "$OUT/$lbl.procs" ||
         { [[ $need_app -eq 1 ]] && ! grep -qx app "$OUT/$lbl.procs"; }; then
        dropped=$((dropped + 1)); rm -f "$OUT/$lbl.own"; continue
      fi
      counts+=( "$(comm -23 "$OUT/$lbl.own" "$OUT/idle.union" | wc -l)" )
    done
    if [[ ${#counts[@]} -eq 0 ]]; then
      printf '%s|%s|-|-|%s\n' "$name" "$wl" "$dropped" >> "$OUT/results"
      echo "  $name/$wl: every run discarded"
      continue
    fi
    sort -u "$OUT/$name-$wl"-*.own > "$OUT/$name-$wl.raw"
    comm -23 "$OUT/$name-$wl.raw" "$OUT/idle.union" > "$OUT/$name-$wl.union"
    med=$(printf '%s\n' "${counts[@]}" | sort -n \
      | awk '{a[NR]=$1} END {print a[int((NR + 1) / 2)]}')
    printf '%s|%s|%s|%s|%s\n' "$name" "$wl" "$med" \
      "$(wc -l < "$OUT/$name-$wl.union")" "$dropped" >> "$OUT/results"
    echo "  $name/$wl: median $med, union $(wc -l < "$OUT/$name-$wl.union"), $dropped discarded"
  done
done

echo
echo "distinct host kernel functions, median of $RUNS runs, idle subtracted"
printf '%-8s' runtime; printf ' %8s' "${WORKLOADS[@]}"; printf '\n'
for name in "${RT_NAMES[@]}"; do
  printf '%-8s' "$name"
  for wl in "${WORKLOADS[@]}"; do
    printf ' %8s' "$(awk -F'|' -v r="$name" -v w="$wl" \
      '$1 == r && $2 == w {print $3}' "$OUT/results")"
  done
  printf '\n'
done

if [[ -s "$OUT/profile-rejections.txt" ]]; then
  echo
  echo "syscalls each runtime refused to build a filter for"
  awk '{c[$1]++} END {for (r in c) printf "  %-8s %d\n", r, c[r]}' \
    "$OUT/profile-rejections.txt"
  echo "  full list: $OUT/profile-rejections.txt"
fi

echo
echo "raw function sets: $OUT/*.union"
