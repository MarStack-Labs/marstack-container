# The kernel surface of starting a container

A runtime spends its whole life as root. It holds `CAP_SYS_ADMIN`, it is the thing that creates
namespaces and writes cgroups, and when it is finished it exits and hands a much less privileged
process the machine. Everything dangerous it will ever do, it does in that window.

Nobody measures that window. Published comparisons of `runc`, `crun` and `youki` measure how *fast*
they start a container and how much memory the result costs. Both are real, and both are largely
settled: `youki` reached parity with `runc` and moved nothing, and per-container memory belongs to
whoever removes the shim.

This measures something else — how much of the kernel a runtime touches while it is privileged.

## The metric

James Bottomley's *horizontal attack profile* approximates exposure as the amount of kernel code a
workload traverses, on the assumption that bug density is roughly uniform, so more code reached means
more chance of reaching a bug. He counts distinct kernel functions entered, traced with `ftrace`.

Bottomley applied it to *isolation platforms* at steady state: a container versus a VM, running the
same application. Later work (van Rijn and Rellermeyer, Middleware '21) extended it by weighting each
function with an exploitability score.

Applying it at steady state to OCI runtimes would measure nothing. Once a container is running, the
runtime has already exited; `runc`, `crun` and `mars` all leave behind the same namespaces and the
same process. The difference lives entirely in the setup path, which is exactly the part that runs as
root.

## Running it

```sh
sudo -E scripts/hap-bench.sh              # all four workloads
sudo -E RUNS=9 scripts/hap-bench.sh exec  # one workload, more repetitions
```

The workload is a static C program that returns immediately, so what is counted is the runtime's own
work rather than an application's. That choice follows Jansen et al., who use a minimal C service for
the same reason.

## Three ways to get a wrong number

Every one of these produced a plausible, wrong result before it was caught. They are the reason the
script asserts rather than trusts.

**Per-PID trace filters lose children.** `trace-cmd -F -c` is documented to follow forks, and it does
follow `runc`'s. It silently failed to follow `crun`'s container process, which made `crun` look three
times leaner than `runc`. The script traces globally and attributes afterwards by process name.

**Global tracing catches the neighbours.** With the filter removed, `containerd` and `udisksd` land in
the same trace. One `runc` run picked up 875 functions that were not its own, including 74 OverlayFS
functions that a plain-directory bundle cannot possibly reach. Attribution by process name is what
separates the runtime's work from the machine's.

**A runtime that fails still produces a number.** `runc spec` writes `ociVersion: 1.3.0`; `crun`
1.14.1 rejects it with `unknown version specified` and exits 1. Measured with stderr hidden, that
failure looked like an extremely efficient runtime. Every run is now checked for exit status and for
the container process appearing in the trace; runs that fail either check are discarded and counted.

Three idle traces are taken and their union subtracted, so kernel background work is not charged to
anyone.

## Results

aarch64, Linux 6.8, five runs per cell, median, idle subtracted, all runtimes sharing one seccomp
profile. `tty` is a detached start with a pty passed over a console socket, so it covers creation
only and is not comparable in absolute terms to the columns that run to container exit.

| runtime | `run` | `vol` | `exec` | `tty` |
|---|---|---|---|---|
| `mars` | **1542** | **1542** | **494** | **1545** |
| `crun` 1.14.1 | 2030 | 2030 | 889 | 1984 |
| `runc` 1.5.1 | 2361 | 2355 | 1134 | 2370 |

`mars` reaches 24% less kernel than `crun` and 35% less than `runc` on a plain start, and 44% / 56%
less on `exec` — the operation a Kubernetes exec probe repeats for the lifetime of a pod.

Four things fall out of the matrix:

**It is not that `mars` skips work.** Namespace creation, `pivot_root`, cgroup setup and capability
handling all appear at parity; on cgroups `mars` matches `runc` and touches eight times what `crun`
does. Of the 1000 functions `runc` reaches on a plain start and `mars` does not, only 10 are thread,
futex or scheduler functions — the Go runtime is not the explanation, which is the opposite of what
the shim's memory cost would suggest. 301 are file, path and `/proc` traversal, and 116 are
networking.

**A bind mount is free.** `vol` costs the same as `run` to the function for `mars` and `crun`, and six
fewer for `runc`. The mount machinery has already been walked to assemble the rootfs.

**A pty costs almost nothing.** `tty` lands within a few percent of `run` for all three despite
allocating a terminal and passing a descriptor over a socket.

**The ordering is stable across every workload.** Four different operations, the same ranking and
roughly the same ratios. A measurement artefact would have to survive all four to explain that.

The 29 functions `mars` reaches that `runc` does not are its own instrumentation:
`cgroup_events_show`, `memory_events_show`, `cpu_stat_show`, `cgroup_base_stat_cputime_show`,
`__arm64_sys_ppoll` — reading the cgroup event and statistics files that
[`failure-modes.md`](failure-modes.md) is built on.

## What the benchmark found in `mars`

Widening the workload to cover seccomp turned up a defect the narrow one hid. Against the profile
Podman and CRI-O ship, `mars` refused to start at all:

```
config.json is invalid: add a seccomp rule for bdflush:
The library doesn't permit the particular operation
```

59 syscall names had to be removed before it would run — `bpf`, `setns`, `chroot`, `init_module`,
`perf_event_open`, `userfaultfd`, `kexec_load` among them. `runc` and `crun` accepted the same
profile unchanged, removing none.

The first diagnosis was wrong, and worth recording because it was plausible. Those names look like
syscalls that do not exist on aarch64, so the obvious reading was that `libseccomp` could not resolve
them. But `mars` already skipped unresolvable names; the failure came one step later, from
`seccomp_rule_add`.

That message is `libseccomp`'s wording for `EACCES`, and `seccomp_rule_add` returns `EACCES` for a
rule whose action equals the filter's *default* action — a rule that asks for what the filter already
does. These profiles deny by default and then spell out denials for the privileged syscalls, so every
such rule is redundant by construction. All 59 rejected names came from `SCMP_ACT_ERRNO` entries
under an `SCMP_ACT_ERRNO` default; not one was an architecture problem.

Getting the cause right made the fix narrow. `mars` now tolerates `EACCES` **only** when the rule's
verdict equals the default action, which cannot change what the filter permits: the syscall was
already denied by the default and stays denied. Every other `libseccomp` error is still fatal, and a
deny rule under an `SCMP_ACT_ALLOW` default — where the rule carries the whole policy and dropping it
would open the syscall it was written to close — has a different action from the default, so it never
takes the tolerant path. A unit test asserts exactly that case.

All three runtimes now share the unmodified 442-name profile.

## Limits

The number is an approximation, and Bottomley says so: counting function entries cannot see control
flow *inside* a function, so a ten-line function and a five-hundred-line one count the same.
Basic-block coverage through `kcov` is the honest version, and Ubuntu's generic kernel ships with
`CONFIG_KCOV` off — it needs a kernel built for the purpose.

Beyond that: one architecture, so these figures cannot be lined up against published x86 results; one
kernel version; and a guest kernel under Apple's hypervisor rather than bare metal. The comparison
between runtimes is sound because all three meet identical conditions. The absolute values are not
portable.
