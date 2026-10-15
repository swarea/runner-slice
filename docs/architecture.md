# Architecture

RunnerSlice is Bash and systemd, with a little Python. It has no daemon, no
database, no API and no state of its own. Everything it decides comes from
two sources:

- **the inventory**: a directory of plain files;
- **the host**: systemd, the cgroup and process trees, accounts and files.

The diagram shows only what exists.

```text
            /etc/runner-slice  (root-owned inventory)
            fabric.conf  runner-release.conf  profiles/*.conf
                              │
                              ▼
   bin/runner-slice ──► fabric/fabric-validate.sh ─┐
        (dispatch)     fabric/fabric-render-…sh  ─┼─► fabric/fabric-lib.sh
                       fabric/fabric-apply.sh   ──┤    validate · derive masks
                       fabric/fabric-check.sh   ──┤    render units · cache
                       fabric/fabric-status.sh  ──┘
                              │                     fabric/host-lib.sh
                              │                     preflight · accounts · dirs
                              ▼                     job state · namespace proofs
      host:  /etc/systemd/system/<slice>, <prefix>-<id>-runner.service
             /var/lib/<prefix>-<id>/{runner,work}   accounts <user-prefix>-<id>
             one slice (CPUQuota, MemoryMax, TasksMax, IPAddressDeny)
                              │
                              ▼
      GitHub: each runner registered by a person to one repository;
              fabric-status.sh reads GitHub's view with gh, unprivileged
```

## Layers

- **Inventory layer (`fabric/fabric-lib.sh`).** Pure functions of the
  inventory: validation, peer mask derivation and unit rendering. It needs no
  root and no host, so all of it runs offline (`runner-slice validate`,
  `render`). "Fabric" is the internal name of this layer (decision 0003).
- **Host layer (`fabric/host-lib.sh`).** The only code that reads the host,
  in two kinds:
  - **primitives that change it:** accounts, directories, unit files;
  - **primitives that prove what it is running:** effective systemd
    properties, a service's mount table, job state from its cgroup.

  The roots it reads (`HOST_ROOT`, `CGROUP_ROOT`, `PROC_ROOT`) and the trusted
  owner are fixed in the file. The environment can never set them.
- **Entry scripts.** `fabric-apply.sh` converges, `fabric-check.sh` proves,
  and `fabric-status.sh` asks GitHub. `bin/runner-slice` only translates a
  subcommand into one of them.

## Decisions that shape the code

- **Rendering, not templating by hand.** Every unit is rendered from the
  inventory. The installed file must equal the rendering byte for byte, and
  each unit's first line marks it as RunnerSlice's. A drop-in is reported as
  drift, not merged.
- **Peers are derived.** A runner's unit masks every other runner's runtime
  root, computed from the whole inventory. Adding a runner never means editing
  another profile.
- **One slice for all runners.** The limits bound CI as a whole against the
  rest of the host. A dash in a slice name is hierarchy, so the cgroup path is
  always taken from systemd, never built from the name.
- **Jobs win.** Before replacing a unit or restarting a runner, apply reads
  the runner's job state from its cgroup and `/proc`. `Runner.Worker` exists
  only while a job runs. A busy or unknown runner keeps its current unit, and
  the difference stays visible until a later run.
- **Registration belongs to a person.** It needs a one-hour token, and the
  files it writes are credentials. Apply prints the command and stops.
- **Check never trusts the declaration it checks.** See
  [threat-model.md](threat-model.md).
- **Fail closed.** Anything unreadable is a failure in `check` and a refusal
  in `apply`.

## What happens on `apply PROFILE`

1. **Preflight.** Distribution, architecture against the release seed, systemd
   249 or later, cgroup v2 and its controllers, capacity against the limits,
   root-only configuration and tool, required commands.
2. **Inventory validation**, for the whole fleet.
3. **Ownership.** A unit of the same name that RunnerSlice did not write stops
   the profile.
4. **Account.** A system account with no supplementary groups. A person's
   account of that name is refused.
5. **Directories.** The runtime root is `root:<account> 0750`. `runner/` and
   `work/` belong to the account.
6. **Packages** named by the release seed, and only those.
7. **Release.** Download, verify the SHA-256, unpack, write the seed marker.
8. **Registration.** If absent, print the command and wait. If present, its
   repository, name and work folder must match the profile.
9. **Units.**
   - The slice is installed if it changed, which needs only a reload.
   - The service unit is installed if it changed and the runner is not busy or
     unknown.
10. **Service.** Enable and start, or restart once if its own unit changed.

`apply` without a profile first refuses if:

- an installed runner unit of RunnerSlice's is not in the inventory;
- any registered runner is busy or unknown.

Otherwise it runs each profile in turn, checking job state again before
each unit change.

## Files on the host

| Path | Owner | Written by |
|---|---|---|
| `/etc/systemd/system/<slice>` | root 0644 | apply |
| `/etc/systemd/system/<prefix>-<id>-runner.service` | root 0644 | apply |
| `/var/lib/<prefix>-<id>/` | root:<account> 0750 | apply |
| `/var/lib/<prefix>-<id>/.runner-slice-seeded` | root | apply, after a complete unpack |
| `/var/lib/<prefix>-<id>/runner/` | <account> 0750 | apply (release), the runner (updates) |
| `/var/lib/<prefix>-<id>/runner/.runner`, `.credentials*` | <account> 0600 | the runner, at registration by a person |
| `/var/lib/<prefix>-<id>/work/` | <account> 0750 | the runner (jobs) |
| `/home/<account>` | <account> | useradd |
