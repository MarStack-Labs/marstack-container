# Contributing

Thanks for taking the time. This is pre-1.0 and not production software, so the shape of things can
still change — if you are about to spend real effort, open an issue first and we can agree on the
approach before you write it.

This project exists to understand the layer Docker hides, which changes what a finished change looks
like. The bar is not "it works". It is "here is the kernel state that proves it works, and here is
the assertion that reads it".

## Getting set up

Rust 1.85 or newer, `libseccomp`, and a Linux kernel with a pure cgroup v2 hierarchy. Nothing else.

Linux only. It needs namespaces, cgroups and `libseccomp`, and it does not build on macOS. A
[Lima](https://lima-vm.io) VM definition is included so the environment is reproducible.

```sh
git clone git@github.com:MarStack-Labs/marstack-container.git
cd marstack-container

limactl start --name=mars-dev ./lima/mars-dev.yaml
limactl shell mars-dev

make preflight    # check the host before blaming the build
make check        # the gate: fmt, clippy with -D warnings, unit tests
make integration  # 128 assertions against kernel state, needs root
```

`make preflight` first, always. Most of what goes wrong is the host rather than the code, and the
one that stops people is **a VPS that is itself a container** — OpenVZ, LXC and most budget plans
share the provider's kernel, which blocks `pivot_root` and cgroup delegation. No amount of `sudo`
changes that.

## What a change looks like

**An assertion reads the kernel, not the runtime.** The integration suite checks `/proc`,
`/proc/mounts`, `/sys/fs/cgroup`, `ip -o link` and wait statuses. A test that asserts on what `mars`
printed about itself proves only that `mars` is self-consistent.

**A change to behaviour comes with a test that fails without it.** The check that works: break the
rule you just wrote — invert the condition, delete the guard, reverse the ordering — and see whether
a test goes red. If none does, the test describes the code rather than holding it to anything.

That is not a slogan here. Three separate measurement faults in `scripts/hap-bench.sh` each produced
a plausible, wrong number before an assertion caught it, and the numbers were wrong in the flattering
direction every time. Two integration bugs had been hiding each other for months: a relative runtime
path made 96 assertions fail identically, and fixing that revealed an OOM test that hung for
nineteen minutes because it never denied swap.

**A test that cannot fail is worse than no test.** If a runtime exits non-zero, or a process never
appears where it should, say so and discard the run rather than recording a number from it.

**Refuse rather than guess.** When a `config.json` is ambiguous or the host is not what was expected,
say no and say which check refused. A silent fallback becomes someone else's incident.

**Error messages are for the person reading them at 3am.** Say what happened and what they can do
about it. `rootfs /tmp/x/rootfs does not exist or is not a directory` names the path; that is the
minimum.

**No comments.** Explain a trap in the commit body or in `docs/`, where it is read by someone
deciding whether to trust this thing rather than only by someone already inside the file.

## Things that will be turned down

Not because they are bad ideas, but because they are decisions this project has already made. Each
is argued in the README under "Scope":

- Image pulling from registries — containerd's job; the runtime is called after the bundle exists
- CNI networking — the namespace is created, populating it belongs to a plugin
- CRI — the kubelet interface sits a layer above an OCI runtime
- cgroup v1 or the systemd cgroup driver — a second driver doubles the surface for no insight
- Checkpoint and restore — a project of its own

A dependency is also a decision. The cgroup driver and the OTLP exporter are hand-written on
purpose: one because delegating it would delegate away the point, the other because the SDK runs a
background thread and a process that forks must not have one. Adding a dependency needs a sentence
on the work it removes, and that sentence has to survive comparison with the standard library.

## Commits

Conventional commits — `feat:`, `fix:`, `docs:`, `test:`, `build:`, `perf:`, `refactor:`, `chore:`,
`style:` — with an optional scope like `fix(seccomp):`. Subject in the imperative, under 72
characters.

The body says **why**, and names any trap a future reader would otherwise hit. If you found a bug
while writing the change, say how you found it; that is often more useful than the fix. If your first
diagnosis was wrong, say that too — the seccomp fix in this repository has a commit body that records
a wrong reading, because the wrong reading was the plausible one.

Keep unrelated changes in separate commits.

## Documentation

Anything that changes what a release contains goes in [CHANGELOG.md](CHANGELOG.md) under
`Unreleased`.

A change to a security property changes [SECURITY.md](SECURITY.md) in the same commit — including
when the change makes the document *less* flattering. A silently-dropped guarantee is worse than a
documented gap.

A phase writeup in `docs/` is where reasoning lives. If you learned something from the kernel that
took a day to work out, that day is worth more written down than the diff is.

## Reporting a vulnerability

Do not open a public issue. See [SECURITY.md](SECURITY.md).
