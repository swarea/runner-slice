# Verification

This document defines:

- how RunnerSlice is verified;
- what each kind of evidence can and cannot show;
- what has been shown so far.

## Evidence levels

Every claim is labelled with the strongest level it has actually reached:

| Level | Meaning |
|---|---|
| DECLARED | Written down as intended behaviour. |
| IMPLEMENTED | Code exists. |
| SYNTHETICALLY TESTED | A drill exercised the real code against fixtures. |
| REAL CLIENT VERIFIED | GitHub accepted a registration and ran a job. |
| DEPLOYED | Applied on a real host. |
| RUNTIME VERIFIED | Observed on the running host: processes, cgroups, mounts, filters. |
| REBOOT VERIFIED | Still true after that host rebooted. |

A green CI run is SYNTHETICALLY TESTED at most. A step that did not run is
reported as SKIPPED or BLOCKED, never as passed.

## Layers

| Layer | Where | What it runs |
|---|---|---|
| Static | `tests/run.sh`, which CI runs | `shellcheck` on every script, including `bin/runner-slice`. |
| Synthetic | `tests/*-drill.sh`, which CI runs | The real scripts, unmodified, against a fixture host. |
| Integration | a disposable VM, by hand | Real systemd, cgroups, accounts, registration and GitHub jobs: the lifecycle acceptance below. |
| Dogfood | a separate private repository, on that VM | RunnerSlice's own drills, run by runners RunnerSlice manages. |

### Static and synthetic

`bash tests/run.sh` runs both layers.

The drills copy the scripts into a temporary directory and point the host
library's roots at a fixture. Accounts and ownership are recorded instead of
created. `systemctl`, `curl`, `dpkg`, `apt-get`, `chown`, `runuser`, `getent`
and `gh` are replaced by fakes that keep state in files. Job detection, mask
resolution and home-namespace proofs run unmodified against fixture cgroup,
process and mount tables.

| Drill | Covers |
|---|---|
| `fabric-drill.sh` | Inventory validation: identities, pools, policy, slice limits, values that reach commands. It also renames the whole fixture to another naming policy, so any example name hard-coded into the library fails. |
| `fabric-render-drill.sh` | Unit and slice rendering, sandbox classes, peer masks. |
| `host-drill.sh` | Preflight, environment immunity, unsafe paths, accounts, job state, mask and home-namespace proofs. |
| `apply-drill.sh` | The lifecycle on a fixture host. It covers: fresh install; the registration boundary; idempotence; slice changes versus unit changes; busy and unknown runners; tampered downloads; interrupted unpacks; foreign units; misregistration; the fleet; orphans; retirement. |
| `check-drill.sh` | A converged fixture host, then one break at a time. Each break must fail and name itself. |
| `status-drill.sh` | GitHub answers that must be trusted, and those that must not. |
| `cli-drill.sh` | Each `runner-slice` command reaches exactly one script. |
| `release-drill.sh` | Archive reproducibility and contents. The unpacked archive's own `tests/run.sh` must pass. |

A change to code that runs as root comes with a drill case that fails without
it. Before each pull request, each new guard is removed by hand, and a drill
case must fail. The pull request records the result, including guards that
survived and why.

### Assumptions the fixtures encode

The drills prove that the scripts judge their inputs correctly. They do not
prove that a real host produces those inputs. Each of these must be observed on
the integration VM:

1. The runner registers and runs jobs under `RestrictNamespaces=yes`.
2. What `systemctl show` prints for:
   - `RestrictNamespaces`, restricted and not;
   - `SupplementaryGroups`;
   - `CPUQuotaPerSecUSec`;
   - `IPAddressDeny`;
   - `IPAddressAllow`;
   - `MemoryHigh` when it is unset.
3. Changed slice limits and a changed `IPAddressDeny` reach running runners
   through a daemon reload, with no restart. This has to be shown by the
   runners' cgroup files and IP filter programs, not by the reload's exit
   code.
4. `ProtectHome=tmpfs` with `BindPaths` produces the mount table the check
   expects.
   - `InaccessiblePaths` masks appear as mounts whose root is
     `/systemd/inaccessible/...`, the field the check reads.
   - They resolve as the check expects, including `/var/run` aliases.
5. Registration and the files it reads:
   - `.runner` has the fields `agentName`, `gitHubUrl` and `workFolder`, and
     a UTF-8 BOM;
   - `config.sh` takes the token from `ACTIONS_RUNNER_INPUT_TOKEN` and
     accepts the printed command;
   - `bin/Runner.Listener.deps.json` names the installed release as
     `Runner.Listener/<version>`, after self-updates too. RunnerSlice reads
     the version there and never executes the runner.
6. Which packages, if any, the runner needs on the target Ubuntu release.
7. `useradd --system` gives a uid below `UID_MIN`, with home `/home/NAME`.
8. GitHub's "remove all custom labels" endpoint drains a runner.

## Lifecycle acceptance

This runs on a disposable VM, separate from every production host, against one
recorded commit. Each item is marked:

- **real**: done on the VM against GitHub;
- **synthetic**: covered by drills only;
- **unverified**: not done yet.

| # | Step | Status |
|---|---|---|
| 1 | Install on a clean VM, from the release archive | unverified (synthetic: release drill) |
| 2 | Preflight accepts the VM and refuses a broken declaration | unverified (synthetic) |
| 3 | Profile validation | unverified (synthetic) |
| 4 | Slice and service applied | unverified (synthetic) |
| 5 | Real GitHub registration, with identity confirmed by apply | unverified |
| 6 | RunnerSlice's drills run as a job on its own runner | unverified |
| 7 | Account, groups, masks and home namespace, as `check` and by hand | unverified (synthetic) |
| 8 | Resource limits in effect: the cgroup files under load | unverified |
| 9 | A second runner as a pool member, and jobs spread across it | unverified (synthetic) |
| 10 | A unit change while a job runs is deferred, and applied after it | unverified (synthetic) |
| 11 | Re-apply changes nothing, and restarts nothing | unverified (synthetic) |
| 12 | Reboot: units start, `check` passes, limits and filters are present | unverified |
| 13 | Failure and recovery: an interrupted unpack, a killed apply, a misregistration | unverified (synthetic) |
| 14 | Deregistration | unverified |
| 15 | Retirement removes exactly what RunnerSlice created | unverified (synthetic) |
| 16 | Nothing left behind: units, accounts, directories, and runners on GitHub | unverified |

Each run records:

- the RunnerSlice commit and tree;
- the VM image and kernel;
- systemd's version;
- each command's exit code;
- the observations, with identifiers removed.

### Environments

Creating either environment needs owner approval, and so does any cost.

- **ARM64:** an Ubuntu 24.04 aarch64 VM on the maintainer's Apple-silicon
  laptop.
  - Candidate tools are UTM or Lima with Apple's Virtualization framework,
    2 vCPU and 4 GiB.
  - Before relying on it, check: systemd PID 1 and cgroup v2 with the
    `cpu`, `memory` and `pids` controllers; outbound access to GitHub;
    reboot behaviour; and the laptop's free memory while it runs.
- **x86_64:** a short-lived Ubuntu 24.04 x86_64 cloud VM.
  - About 2 vCPU and 4 GiB, created for the run and deleted after it.
  - It must be in an account or project separate from production, with no
    access to production networks.
  - The provider, cost cap, run time and deletion procedure are decided before
    it is created.

### Dogfood

The integration VM's runners are registered to a separate private repository,
proposed as `swarea/runner-slice-dogfood`. They are not registered to this
repository.

- **Its workflow** checks out an owner-approved commit of RunnerSlice by SHA,
  and runs `tests/run.sh` on the VM's runners.
- **Each run records** the commit, the tree, and the runner that ran it.
- **These results never appear as checks on RunnerSlice pull requests.** A
  non-sensitive summary goes into the release record.

The README may say RunnerSlice is validated on runners it manages only after
a dogfood run and the lifecycle acceptance have both been recorded for one
commit. The dogfood runners are retired when the acceptance ends. That
retirement is item 15.
