# Product contract

Working title: **runner-fabric** (the name is not final; see "Open decisions").

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

Every claim in this repository is labelled with the strongest level actually
reached, never a stronger one:

| Level | Meaning |
|---|---|
| DECLARED | written down as intended behaviour |
| IMPLEMENTED | code exists |
| SYNTHETICALLY TESTED | a drill exercised the real code against fixtures |
| REAL CLIENT VERIFIED | GitHub accepted a registration and ran a job |
| DEPLOYED | applied on a real host |
| RUNTIME VERIFIED | observed on the running host (processes, cgroups, filters) |
| REBOOT VERIFIED | still true after a reboot of that host |

A green CI run is SYNTHETICALLY TESTED at most. It is never evidence of any of
the levels below it in this table.

## Origin and prior evidence

The code is extracted from a private infrastructure repository. There it has
run six runners for five repositories on a 4-core ARM64 host that also serves
production web traffic, including a two-runner pool for one repository. That
history is evidence that the design works. It is **not** evidence for this
repository's code: the extraction changes names, defaults and the sandbox
baseline, so every level above starts again at IMPLEMENTED here.
`docs/field-report.md` (to be written) records what was learned, without host
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
| Registration as a person's step; retiring a pool member | `fabric/fabric-apply.sh` | SYNTHETICALLY TESTED |
| Read-only runtime conformance | `fabric/fabric-check.sh` | SYNTHETICALLY TESTED |
| Operational status from GitHub | `fabric/fabric-status.sh` | SYNTHETICALLY TESTED |
| Optional deny list for the slice | `slice-ip-deny` in the policy | SYNTHETICALLY TESTED; provider-specific |

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

These are assumptions the drills encode as fixtures. Each must be observed on
a real host before any claim beyond SYNTHETICALLY TESTED.

- The runner registers and runs jobs under `RestrictNamespaces=yes`.
- What `systemctl show` prints for `RestrictNamespaces` (restricted and
  unrestricted), for `SupplementaryGroups`, and for `CPUQuotaPerSecUSec`.
- Changed slice limits, and a changed `IPAddressDeny`, take effect for
  running runners on daemon-reload, without a restart.
- `ProtectHome=tmpfs` with `BindPaths` produces the mount table the check
  expects.
- Which packages the runner needs on the target Ubuntu release, if any, for
  `apt-dependency`.
- `useradd`, `install` and `tar` behave as the fixture doubles assume.

## The CI evidence tool

The source repository also has a read-only tool that judges a commit from
GitHub's evidence: tested tree, policy and skipped-job semantics. It answers a
different question ("what did CI actually prove?") from this project ("where
and how do runners run?"). It also depends on its home repository's
default-branch policy and on its own copy on that branch.

**Decision:**

- It stays out of v1 and stays in its source repository.
- It is a candidate for its own small project later, decided on its own merits.
- Nothing here depends on it, and nothing here removes it.

## Supported platforms

The policy is to list only what has been tested, at the level reached.

| Platform | Status |
|---|---|
| Ubuntu with systemd ≥ 249, cgroup v2, x86_64 | target for the first verification VM; not yet verified |
| Ubuntu with systemd ≥ 249, cgroup v2, aarch64 | source of the prior evidence; not yet verified for this code |
| Anything else | unsupported, and refused by preflight |

## Security position (summary; full model in `docs/threat-model.md`)

**What it does:**

- Separates runners from each other and from declared host paths, using Unix
  accounts, `ProtectHome`, `ProtectSystem`, `InaccessiblePaths`,
  `NoNewPrivileges` and namespace restriction.
- Bounds CPU, memory and task count for all runners together.

**What it does not do:**

- It is not a boundary against malicious code.
- The kernel, the network and anything else the host can reach stay shared.
- Membership of the `docker` group, or access to the Docker socket, is root on
  the host. Runner accounts get no supplementary groups, and the checks verify
  that from inside the runner's namespace.

## Verification design

Three paths, never merged into one claim:

1. **Public CI.**
   - Runs on GitHub-hosted runners only.
   - Covers static checks and every drill.
   - Never connects to a self-hosted runner.
2. **Dogfood acceptance.**
   - A disposable VM, separate from any production host.
   - Runners installed by this project, registered to a private test
     repository that only the maintainer can push to.
   - That repository's workflow checks out an approved, immutable commit of
     this project and runs its drills.
   - Each record keeps the commit tested and the tree checked out.
   - Results do not appear as checks on public pull requests; a non-sensitive
     summary goes into the release acceptance record.
3. **Lifecycle acceptance on the same VM.** In order:
   1. preflight
   2. plan
   3. apply
   4. register
   5. a real job
   6. conformance
   7. add a pool member
   8. refuse to change a busy runner
   9. re-apply with no restarts
   10. reboot and re-check
   11. retire, deregister and remove
   12. confirm nothing is left behind

The README may say "built and validated using runners managed by itself" only
after paths 2 and 3 have run against a recorded commit.

## Release stages

| Stage | Exit criteria (evidence, not intent) |
|---|---|
| Foundation | contract agreed; core extracted; drills pass here (SYNTHETICALLY TESTED) |
| Alpha | preflight, converge, register, status and conformance ported; one runner REAL CLIENT VERIFIED on the test VM |
| Beta | pools, busy guard, idempotent re-apply and retire RUNTIME VERIFIED on the test VM; security and docs reviewed |
| 1.0 | fresh install from the docs alone; dogfood and lifecycle acceptance complete; REBOOT VERIFIED; release archive with checksums |

The version follows the evidence. No stage is skipped to reach a number.

## Open decisions (owner)

- **Name.** The working title is used until decided.
- **Licence.** MIT is proposed, matching the organisation's other public
  project.
- **Public repository creation and visibility timing.**
- **Test VM.** Where it runs and with what resources. It must be separate from
  production.
- **Private dogfood repository.** Its creation, and the one-hour registration
  token step.
