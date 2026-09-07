# Security policy

## Supported versions

None. `marstack-container` is pre-release, has no tagged releases, and is not production software —
that is its stated purpose, not modesty about the code. It exists to build a model of the runtime
layer. Do not run it anywhere that matters.

## Reporting a vulnerability

Open a private security advisory through GitHub on this repository. Please do not open a public
issue for a vulnerability.

Include what you did, what happened, and what you expected. A reproduction against a local bundle is
the most useful thing you can send: a `config.json` and the command you ran beats a description.

Findings that let a process reach the host filesystem outside its rootfs, keep a capability the spec
dropped, escape the cgroup it was placed in, execute a syscall the seccomp profile denies, or run as
a uid the user namespace did not map are the highest severity in this project.

## Where the privilege actually is

A runtime holds `CAP_SYS_ADMIN` for the whole of container creation and then exits. Everything
dangerous it can do, it does in that window, which is why the size of that window is measured rather
than assumed: [`docs/attack-surface.md`](docs/attack-surface.md) counts the distinct host kernel
functions traversed while privileged, next to `runc` and `crun`, and states what the number cannot
tell you.

The isolation and hardening decisions themselves are argued in
[`docs/01-isolation.md`](docs/01-isolation.md) and
[`docs/05-hardening.md`](docs/05-hardening.md) — including the orderings the kernel enforces, which
broke twice before they were written down.

## What is not covered

- **Rootless without privilege is unfinished.** The user namespace machinery works and is tested,
  but the runtime still expects to be started with privilege. Treat any claim of rootless safety as
  unproven here.
- **SELinux and AppArmor labels are parsed and ignored,** not applied. A bundle asking for a label
  gets no error and no label. This is recorded rather than hidden because a silently-dropped label
  is worse than a refused one.
- **`SCMP_ACT_NOTIFY` is refused,** since it needs a listener process to receive the notification
  descriptor.
- **No CNI networking.** The network namespace is created and left empty.
- **The attack surface figures are one architecture, one kernel, and a guest kernel** rather than
  bare metal. The comparison between runtimes holds because all three meet identical conditions; the
  absolute numbers do not travel.

## What runs on every commit

`cargo clippy` with warnings as errors, the unit tests, an integration suite of 128 assertions that
read kernel state rather than the runtime's own claims, and the OCI validation suite against both
`mars` and `runc` for comparison.
