# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[semantic versioning](https://semver.org/spec/v2.0.0.html). Before 1.0 the CLI, the annotations and
the on-disk state may change between minor versions.

A release ships one binary, `mars`, which is the whole runtime: it takes a filesystem bundle and a
`config.json` and turns it into an isolated process.

To cut a release, rename `Unreleased` below to the version and the date, commit, then push the
matching `v` tag. The release workflow takes its notes from the section named after the tag, so a
tag with no section of its own falls back to a bare list of commits.

Nothing is tagged yet, so everything below sits under `Unreleased`.

## [Unreleased]

Pre-release, and deliberately not production software: this exists to build a model of the layer
Docker hides, not to displace `runc`. Read "Before production" in
[the usage guide](https://marstack-labs.github.io/marstack-container/) before running it anywhere
that matters.

### Added

- **A complete OCI runtime.** `create`, `start`, `state`, `kill`, `delete`, `exec`, `list`, `ps`,
  `pause`, `resume`, `events`, `update`, `spec`, `features`, all five lifecycle hooks, and a console
  socket over `SCM_RIGHTS`. 26 of the OCI validation suite pass, next to `runc` 1.5.1's 22 on the
  same host.
- **Isolation written by hand.** mount, pid, uts, ipc, user, cgroup, net and time namespaces,
  `pivot_root`, the standard mounts and device nodes. The three-level fork chain is forced by the
  kernel: `unshare(CLONE_NEWPID)` does not move the caller into the new namespace, and `uid_map` has
  to be written from outside it by a privileged process.
- **A cgroup v2 driver written against `cgroupfs`,** covering `memory`, `cpu`, `pids`, `cpuset` and
  `io`. Delegating this to a crate would delegate away the point of the project.
- **OverlayFS rootfs assembly** as a documented extension rather than a spec feature. Three
  `dev.mars.overlay.*` annotations, so the `config.json` stays valid for any other runtime, which
  will ignore them.
- **Hardening:** capabilities, seccomp, `no_new_privs`, read-only rootfs, `maskedPaths` and
  `readonlyPaths`, sysctls, rlimits, `oomScoreAdj`, and user namespaces with a `newuidmap` fallback.
- **A Docker drop-in.** `docker run --runtime=mars` covering `run`, `run -it`, `exec`, `stop` and
  `--memory`, with `TRACE=1` to log how Docker calls a runtime it has never seen.
- **OTLP trace export with no background thread.** The OpenTelemetry SDK exports on one, which a
  process that forks or calls `setns` must not have, so the exporter is around 120 lines that build
  OTLP/HTTP JSON and write one POST.
- **An integration suite of 128 assertions** that read kernel state — `/proc`, `/proc/mounts`,
  `/sys/fs/cgroup`, `ip -o link`, wait statuses — rather than trusting what the runtime reports
  about itself.
- **Nine production failure modes reproduced** with the evidence read out of the kernel, in
  [`docs/failure-modes.md`](docs/failure-modes.md). Among them: an OOM kill does not reliably
  produce exit 137, because the kernel picks its victim by badness score and PID 1 often survives.
- **A kernel attack surface benchmark,** `scripts/hap-bench.sh`, counting the distinct host kernel
  functions a runtime traverses while it holds root. 1542 for `mars` against `crun`'s 2030 and
  `runc`'s 2361 on a plain start, and 494 against 889 and 1134 on `exec`. Method, the three
  measurement faults that produced wrong answers first, and the limits are in
  [`docs/attack-surface.md`](docs/attack-surface.md).

### Fixed

- **A standard seccomp profile no longer refuses to load.** `libseccomp` returns `EACCES` for a rule
  whose action equals the filter's default action, and the profiles Podman and CRI-O ship deny by
  default and then spell out denials for privileged syscalls — so 59 rules were redundant by
  construction and each one was fatal. `EACCES` is now tolerated only when the rule's verdict equals
  the default, which cannot change what the filter permits.
- **The integration suite resolves the runtime path before changing directory.** It had never passed
  in CI: 96 of 118 assertions failed on a relative `MARS` that could not survive the `cd` into a
  bundle.
- **The OOM test denies swap, so the kill actually happens.** It set `memory.limit` but not
  `memory.swap`, and the `awk` loop writes each page once and never touches it again — so on a host
  with swap the kernel satisfied `memory.max` by spilling cold pages and killed nothing. The test
  hung for nineteen minutes in CI before it was noticed.

### Changed

- Renamed from `mars-container-runtime` to `marstack-container`, and moved to the `MarStack-Labs`
  organisation alongside `marstack-cloud`, `marstack-secrets` and `marstack-access`. GitHub redirects
  the old paths, but the `Cargo.toml` `repository` field was already stale and now points at the new
  one.

### Not implemented

Rootless without any privilege. The user namespace machinery works and is tested, but `mars` still
expects to be started with privilege; a fully rootless run also needs a delegated cgroup under
`user.slice`, `fuse-overlayfs` or `userxattr` for whiteouts, and `slirp4netns` for networking.

### Out of scope

Image pulling from registries, CNI networking, checkpoint and restore, CRI, cgroup v1, the systemd
cgroup driver, SELinux and AppArmor labels (parsed and ignored rather than silently claimed), and
`SCMP_ACT_NOTIFY`.
