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
| Public CI | the `check` workflow, on GitHub-hosted `ubuntu-24.04` | `tests/run.sh` on every push to `main` and every pull request. It never runs on a self-hosted runner. |

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
prove that a real host produces those inputs. Each assumption below was
checked on the ARM64 acceptance VM
([acceptance/2026-10-arm64.md](acceptance/2026-10-arm64.md)). An x86_64 host
has not been checked.

| # | Assumption | Result on Ubuntu 24.04 aarch64, systemd 255 |
|---|---|---|
| 1 | The runner registers and runs jobs under `RestrictNamespaces=yes` | **Holds.** Real jobs ran, and `unshare -U` was refused inside them. |
| 2 | What `systemctl show` prints | **Partly wrong, fixed.** `RestrictNamespaces` prints `yes`, `no` or a list, not an empty value; the check now expects that. `CPUQuotaPerSecUSec=1s`, byte values for memory, `/32` on `IPAddressDeny`, and empty `IPAddressAllow` and `SupplementaryGroups` are as assumed. `MemoryHigh` when unset was not observed. |
| 3 | Slice changes reach running processes on reload, without a restart | **Holds**, for `IPAddressDeny` and `memory.max`. It was shown on a live process in the slice by its connections and cgroup files, with the same PID before and after. The live runners carried the deny from their start, and real jobs could not reach it. |
| 4 | The mount table the check reads | **Holds.** Masks are mounts rooted at `/systemd/inaccessible/…`. `/home` is a tmpfs with only the account's own home bound. Read from the real Listener process. |
| 5 | Registration files and inputs | **Holds.** `.runner` has a UTF-8 BOM and the fields `agentName`, `gitHubUrl` and `workFolder`. `config.sh` reads `ACTIONS_RUNNER_INPUT_TOKEN`, for both registration and removal. `deps.json` names `Runner.Listener/2.338.0`. A runner self-update was not observed. |
| 6 | Packages the runner needs | **`liblttng-ust1t64`** is the only one missing from the Ubuntu 24.04 cloud image. |
| 7 | `useradd --system` gives uid < `UID_MIN` with home `/home/NAME` | **Holds** (uids 995 and 997). |
| 8 | Removing a runner's custom labels drains it | **Holds** as far as observed: after removal, only `self-hosted`, `Linux` and `ARM64` remained. That no job was then assigned was not separately tested. |

## Lifecycle acceptance

This runs on a disposable VM, separate from every production host, against one
recorded commit. Each item is marked:

- **real**: done on the VM against GitHub;
- **synthetic**: covered by drills only;
- **unverified**: not done yet.

| # | Step | Status (ARM64 VM) |
|---|---|---|
| 1 | Install on a clean VM, from the release archive | **PASS.** Found #16 (the archive was group-writable); fixed |
| 2 | Preflight accepts the VM and refuses a broken declaration | **PASS** |
| 3 | Profile validation | **PASS** |
| 4 | Slice and service applied | **PASS** |
| 5 | Real GitHub registration, with identity confirmed by apply | **PASS.** Two runners |
| 6 | RunnerSlice's drills run as a job on its own runner | **PASS.** 436 cases, on each runner |
| 7 | Account, groups, masks and home namespace, as `check` and by hand | **PASS.** `check`, the live process, and boundary jobs |
| 8 | Resource limits in effect: the cgroup files under load | **PASS.** Both runners busy, held to one CPU and MemoryHigh |
| 9 | A second runner as a pool member, and jobs spread across it | **PASS.** Jobs observed on each; assignment is GitHub's |
| 10 | A unit change while a job runs is deferred, and applied after it | **PASS.** Real hold jobs; exactly one restart afterwards |
| 11 | Re-apply changes nothing, and restarts nothing | **PASS** |
| 12 | Reboot: units start, `check` passes, limits and filters are present | **PASS.** Guest reboot; boundary jobs after it |
| 13 | Failure and recovery: an interrupted unpack, a killed apply, a misregistration | **PASS** for the killed download and the killed unpack. A misregistration stays SYNTHETIC |
| 14 | Deregistration | **PASS.** Found a rejected `--unattended`; fixed |
| 15 | Retirement removes exactly what RunnerSlice created | **PASS** |
| 16 | Nothing left behind: units, accounts, directories, and runners on GitHub | **PASS.** Only the shared slice unit remains, by design |

Unknown job state could not be produced safely on a healthy host as root, so
it remains SYNTHETICALLY TESTED. x86_64 is not verified.

The retirement and reader changes from the post-acceptance review (#18) were
run on the same VM, at RUNTIME VERIFIED, with a test-only profile that was
never registered. That run covered:

- leftover processes, by effective and by saved uid;
- `userdel` failing;
- a runtime root that could only be partly removed, and the retry after it;
- `USERGROUPS_ENAB no`;
- a group in use, and a leftover home;
- a symlinked `bin/`;
- the unpack mode.

The results are in [the acceptance record](acceptance/2026-10-arm64.md). An
unreadable `/proc`, and malformed runner files, remain SYNTHETICALLY TESTED.

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

The integration VM's runners were registered to a separate private
repository, `swarea/runner-slice-dogfood`, never to this one. They were
retired when the acceptance ended.

- **Its workflow** checks out an owner-approved commit of RunnerSlice by SHA,
  and runs `tests/run.sh` on the VM's runners.
- **Each run records** the commit, the tree, and the runner that ran it.
- **These results never appear as checks on RunnerSlice pull requests.** A
  non-sensitive summary goes into the release record.

The README may say RunnerSlice is validated on runners it manages only after
a dogfood run and the lifecycle acceptance have both been recorded for one
commit. The dogfood runners are retired when the acceptance ends. That
retirement is item 15.
