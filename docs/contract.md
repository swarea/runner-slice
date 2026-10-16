# Product contract

**RunnerSlice**: a systemd-native manager for self-hosted GitHub Actions runners.
The name and its spelling are recorded in decision 0003.

This document is the single statement of what the project is, what it is not,
and what has to be true before each release stage. Other documents link here
rather than restate it.

## What it is

A small, systemd-native way to run several GitHub Actions self-hosted runners
on one Linux host you already operate. Each runner serves one repository under
its own Unix account and runtime root. All runners share one resource-limited
systemd slice. Changes are applied idempotently, without restarting a runner
that is busy. A separate read-only check proves the running host matches what
was declared.

It is not a CI server and does not schedule jobs: GitHub assigns jobs to
runners exactly as it does for any self-hosted runner.

### Who it is for

An operator who:

- already has a Linux host with spare capacity, possibly running other services;
- wants persistent, repository-scoped runners for repositories they trust;
- needs a hard ceiling on what CI may take from the rest of the host;
- wants to see, after the fact, whether the host still matches the declaration.

### Who it is not for

- **Untrusted code.** Public repositories that accept pull requests from
  strangers should not run on a persistent runner on a shared host. This
  project does not change that; GitHub says the same.
- **Isolation as strong as a VM.** If you need that, use ephemeral VM-based
  runners: GitHub-hosted, ARC, or GARM with a VM provider.
- **Autoscaling or many hosts.** One host, a fixed set of runners.
- **No host to share.** If you do not already operate a Linux host, hosted
  runners are almost certainly cheaper in time.

## Evidence levels

Every claim is labelled with the strongest evidence level it has reached,
never a stronger one. The levels, and what each kind of test can show, are
defined in [verification.md](verification.md). A green CI run is SYNTHETICALLY
TESTED at most.

## Origin and prior evidence

The code is extracted from a private infrastructure repository. There it has
run six runners for five repositories on a 4-core ARM64 host that also serves
production web traffic, including a two-runner pool for one repository. That
history is evidence that the design works. It is **not** evidence for this
repository's code: the extraction changes names, defaults and the sandbox
baseline, so every level above starts again at IMPLEMENTED here.
[field-report.md](field-report.md) records what was learned, without host
identifiers.

## v1 scope

Each feature maps to code extracted from the source. Nothing in v1 is
written from scratch unless the source could not be generalised.

| Feature | Where | Status |
|---|---|---|
| Declarative inventory: policy, release seed, one profile per runner | `fabric.conf`, `runner-release.conf`, `profiles/*.conf` | SYNTHETICALLY TESTED |
| Fleet validation: unique identities, consistent pools, no secrets in profiles | `fabric/fabric-lib.sh` | SYNTHETICALLY TESTED |
| Unit rendering, with peer runtime roots derived from the inventory | `fabric/fabric-lib.sh` | SYNTHETICALLY TESTED |
| Slice limits declared in the policy and rendered, with no defaults | `fabric/fabric-lib.sh` | SYNTHETICALLY TESTED |
| Pools: several runners for one repository | `fabric/fabric-lib.sh` | SYNTHETICALLY TESTED |
| Host preflight against the declaration: distribution, architecture, systemd, cgroup v2, optional hostname, root-only configuration | `fabric/host-lib.sh` | SYNTHETICALLY TESTED |
| Idempotent converge, busy-runner guard, `--check` plan mode | `fabric/fabric-apply.sh` | SYNTHETICALLY TESTED |
| Registration as a person's step; retiring any runner | `fabric/fabric-apply.sh` | SYNTHETICALLY TESTED |
| Read-only runtime conformance | `fabric/fabric-check.sh` | SYNTHETICALLY TESTED |
| Operational status from GitHub | `fabric/fabric-status.sh` | SYNTHETICALLY TESTED |
| Optional deny list for the slice | `slice-ip-deny` in the policy | SYNTHETICALLY TESTED; provider-specific |
| Refusing what RunnerSlice did not create: foreign units, human accounts, symlinked or non-root inventories | `fabric/fabric-apply.sh`, `fabric/host-lib.sh` | SYNTHETICALLY TESTED |
| Registration identity: the runner is registered as its profile says | `fabric/host-lib.sh` | SYNTHETICALLY TESTED |
| One command: `runner-slice` | `bin/runner-slice` | SYNTHETICALLY TESTED |
| Reproducible release archive with checksum | `scripts/release.sh` | SYNTHETICALLY TESTED |

`tests/run.sh` is the one verification entry point: shellcheck, then every
drill. The drills run the real scripts from a temporary copy whose library
points at a fixture root. Only the host is replaced. No result in this table is
evidence about a real host.

### Excluded from v1

Each of these was considered and refused:

- a daemon, database, web UI or API;
- autoscaling, ephemeral or JIT runners;
- organisation-level runners;
- Kubernetes;
- multiple hosts;
- a rewrite in another language;
- provider adapters for clouds that have not been tested;
- Windows or macOS hosts;
- the CI evidence tool (see below).

## Coupling found in the source, and what happens to it

| Coupling | Class | Resolution |
|---|---|---|
| Slice name hard-coded; cgroup path assumed from it | explicit setting | `slice` in the policy; cgroup path read from systemd at run time |
| Service and install-root naming tied to one prefix | explicit setting | `name-prefix` in the policy |
| Runner account naming | explicit setting | `user-prefix` in the policy |
| Required host label | explicit setting | `host-label` in the policy |
| Mandatory masks naming one host's application, backup and AI paths | host policy, removed | only the Docker socket masks stay mandatory; other masks are the operator's `common-mask` lines |
| Expected hostname, distribution and architecture constants | explicit setting | preflight checks the distribution, an architecture matching the release seed, systemd, cgroup v2, and an optional `host-name` |
| Slice limits in a hand-written unit tuned for one host | explicit setting | `slice-*` keys in the policy, required, with no defaults; the unit is rendered |
| `lib.sh` shared with unrelated host planes | extract minimum | only the helpers the CI scripts use |
| Checks of one host's legacy paths and secret locations | host policy, removed | secret-location checks become declared `protected-path` lines |
| Paths and the cgroup layout assumed by the scripts | explicit setting | cgroup path read from systemd; host roots fixed in the library and never read from the environment |
| Release seed pinned to one architecture and a distribution package | explicit setting | the release file already declares platform and packages; one file per platform |
| Metadata deny for one cloud | provider-specific | `slice-ip-deny`, empty by default; only providers actually tested are documented |
| `baseline` sandbox left namespaces unrestricted on purpose (a migration choice) | changed deliberately | `baseline` restricts namespaces; `userns` is the explicit opt-in (decision 0002) |
| CI evidence tool bound to the source repository's judge and policy | not in v1 | separate follow-up candidate |

## Behaviour changed from the source

Three defects were found while porting the converge script, and they are
fixed here. The source repository is not changed by this project.

- **A slice-only change restarted one arbitrary runner.** Whichever runner
  installed the changed slice first was restarted, although slice properties
  take effect on reload. Now a slice change reloads systemd and restarts
  nothing. Only a runner whose own unit changed is restarted.
- **A deferred restart could be lost.** When a runner was busy, its new unit
  was installed and only the restart was deferred, so the next run found the
  unit current and never restarted it. Now a changed unit is not installed
  while a job runs or its state is unknown. The difference itself remains the
  pending work.
- **Unknown job state was treated as idle on the single-profile path.** That
  path restarted a runner whose job state could not be read. Now unknown
  state refuses the restart everywhere.

## To verify on the test VM

The assumptions the drills encode as fixtures, and the lifecycle acceptance,
are listed in [verification.md](verification.md). Nothing here claims more
than SYNTHETICALLY TESTED until each is observed there.

## The CI evidence tool

The source repository's CI evidence verdict stays out of v1 and stays where it
is. It remains a candidate for its own project (decision 0004).

## Supported platforms

Only what has been verified is listed, in [compatibility.md](compatibility.md).
Preflight refuses anything other than Ubuntu with systemd 249 or later and
cgroup v2. It accepts more than is supported: any systemd other than 255
passes with a warning that it is unverified.

## Security position

RunnerSlice separates runners from each other and from declared host paths,
and bounds what they take together. It is not a boundary against malicious
code: the kernel and the network stay shared, and access to the Docker socket
is root on the host. The model, its mechanisms and its limits are in
[threat-model.md](threat-model.md).

## Verification design

There are three paths, and they are never merged into one claim:

1. **Public CI** on GitHub-hosted runners: static checks and every drill.
2. **Dogfood:** RunnerSlice's own drills on runners it manages, on a
   disposable VM, in a separate private repository.
3. **Lifecycle acceptance** on that VM.

The details are in [verification.md](verification.md). The README may say
RunnerSlice is validated on runners it manages only after paths 2 and 3 have
run against one recorded commit.

## Release stages

| Stage | Exit criteria (evidence, not intent) |
|---|---|
| Foundation | contract agreed; core extracted; drills pass here (SYNTHETICALLY TESTED) |
| Alpha | preflight, converge, register, status and conformance ported; one runner REAL CLIENT VERIFIED on the test VM |
| Beta | pools, busy guard, idempotent re-apply and retire RUNTIME VERIFIED on the test VM; security and docs reviewed; `status` REAL CLIENT VERIFIED with an authenticated `gh`; one x86_64 host RUNTIME VERIFIED; a runner self-update observed |
| 1.0 | fresh install from the docs alone; dogfood and lifecycle acceptance complete; REBOOT VERIFIED; release archive with checksums |

The version follows the evidence. No stage is skipped to reach a number.

## Open decisions (owner)

Decided:

- on 2026-10-15: the name (decision 0003), the MIT licence, and rebase-only
  merges;
- the ARM64 verification VM and the private dogfood repository
  `swarea/runner-slice-dogfood`, used for the acceptance of 2026-10-15/16;
- on 2026-10-16: public visibility. Hosted CI for a public repository needs
  no paid minutes.

Still open, each a separate approval:

- **the first release and tag**;
- **an x86_64 verification host**, and its cost.
