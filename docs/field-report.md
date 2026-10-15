# Field report: the fabric RunnerSlice came from

RunnerSlice was extracted from a runner fabric that has run on one production
host since September 2026. This report records what that host taught. It
explains why RunnerSlice is built as it is, and where the design was wrong.

**None of it is evidence for RunnerSlice's own code.** The extraction changed
names, defaults and several behaviours, so every evidence level in
[verification.md](verification.md) starts again for this code.

Every number below is from that host, with its period and method. Host names,
repository names, network details and account identifiers are left out.

## The host

- **Machine:** an Oracle Cloud Ampere A1 instance with 4 ARM64 cores, running
  Ubuntu 22.04 with systemd 249.
- **What else it runs:** production web services, their databases, and a
  background AI service, each in its own slice.
- **Why it was chosen:** it already existed and had spare capacity, and the
  organisation's GitHub-hosted minutes, on the Free plan, were being exhausted
  by one mobile-app repository.
- **Why this host and not another:** a second candidate host held the
  organisation's canonical data. Running CI code there was rejected.
- **What ran on it:** six persistent repository-scoped runners for five
  repositories. One repository had a two-runner pool from 2026-10-10.
- **The shared slice:** `CPUQuota=250%`, `MemoryHigh=6G`, `MemoryMax=8G`,
  `TasksMax=2048`, `CPUWeight=70`. These were sized for that host and that
  workload, and **are not RunnerSlice defaults**. RunnerSlice has no defaults
  for them.

## What the load looked like

- **Volume.** From 2026-09-14 to 2026-10-14 the host ran about 9,000 job-minutes
  for its two busiest repositories: 8,540 and 509 minutes. The figures are
  GitHub's job timings, summed. One repository was idle for the whole period.
- **One job barely uses the slice.** Cgroup CPU counters were sampled during
  jobs on 2026-10-08. A typical job used about 1.1 of the 2.5 cores the
  quota allows. The test suites were process-spawn bound and single-threaded.
  The busiest repository accounted for about 74% of all CPU the slice had
  used since boot, by the cumulative counter.
- **Parallelism inside a job hits the quota.** Running three test processes
  at once inside one job, the slice was throttled in 82% of scheduler periods.
  Running two, it was throttled in 7%, and the heaviest job went from 12 min
  50 s to 7 min 07 s. Two was kept.
- **Waiting, not running, was the delay.** Over the 7 days to 2026-10-09, a
  pull request took a median of 25 minutes and a 90th percentile of 61 minutes
  from creation to green. Its jobs added up to about 21 minutes. 64% of runs
  overlapped another run of the same repository, queued behind a single runner.
  A replay of the real arrival times reproduced the delay (p50 25.1 / p90 63.2
  minutes).
- **A second runner for the busiest repository** was added on 2026-10-10 as
  a pool member. In the one run measured so far, the three jobs of a run
  finished along a critical path of 14.8 minutes, against 17.9 minutes run one
  after another. Jobs running at the same time each took 1.4 to 1.8 times as
  long as alone.
  - One sample is not a performance result. A 7-day before-and-after
    comparison is planned, and nothing more is claimed until it exists.
  - This experience is why pools exist in RunnerSlice.
- **What did not fit.** The mobile-app repository's Android build needed
  x86_64-only tools under emulation: 18 to 26 times slower per core on
  ARM64, measured on single tools (167 s against 9 s, 52 s against 2 s). Its build also asked for an 8 GiB heap, the whole
  slice. It does not belong on a small shared host.

## Boundaries, and what each one actually rests on

- **Unix accounts per repository.** Each runner has its own account, home
  and runtime root. Homes and runtime roots were mode 750, and no job left a
  process behind after it ended.
- **The Docker socket mask is not what it looks like.** `InaccessiblePaths`
  does not hide a socket the way it hides a directory. The node can stay
  visible. The connection is refused because the runner account holds no
  supplementary group.
  - Relaxing the group rule while trusting the mask would open the socket.
  - RunnerSlice therefore checks group membership and tests write access as
    the account, as well as the mask.
- **Namespaces were unrestricted.** To avoid tightening anything during
  migration, the source's "baseline" sandbox set no `RestrictNamespaces=`. A
  review on 2026-10-15 found every unit unrestricted.
  - RunnerSlice's baseline restricts namespaces, and opening them is an
    explicit per-profile choice (decision 0002).
- **Instance metadata was reachable from every job.** Until 2026-10-15, a job
  could read the instance's metadata endpoint at `169.254.169.254`. The
  unauthenticated v1 form answered.
  - The fix was one `IPAddressDeny=` on the shared slice.
  - What made it work, and was verified on the host with `bpftool`:
    - systemd 249 merges a slice's deny list into each service's own IP filter
      program; nothing is attached to the slice's cgroup;
    - a daemon reload re-attached new programs to the running runners, without
      a restart;
    - every runner got a new program ID, and its address map held the
      metadata address.
  - What was learnt:
    - an `IPAddressAllow` anywhere above the runner would win over the deny,
      so the check refuses one on any ancestor slice;
    - clearing a deny may leave the old program attached, so a rollback needs
      a restart or a matching allow.
  - On that cloud, name resolution went through the local stub resolver,
    which runs outside the slice.
- **What none of this covers.**
  - Loopback services without authentication are reachable from every job.
  - A job can reach anything the host can reach, apart from declared denies.
  - The kernel is shared.

  These are written into [threat-model.md](threat-model.md) as limits rather
  than left implicit.

## Failures that shaped the code

- **Drills that read the real host.** The CI runner for the fabric's own
  repository ran on the host the fabric manages. A drill that fell back to a
  real path when its fixture path was unset saw an empty directory on a
  workstation, and the live runner units in CI.
  - It passed locally and failed in CI.
  - RunnerSlice's library roots are fixed in the file. A drill changes them
    only in its own temporary copy, never through the environment.
- **A race in `printf | grep -q`.** Under `pipefail`, a shell builtin feeding
  `grep -q` failed about once in 400 runs when `grep` exited early. Job-state
  detection uses a here-string for this reason.
- **Restarts that were lost or unsafe.** Porting the converge script surfaced
  three defects:
  - a slice-only change restarted an arbitrary runner;
  - a unit installed under a busy runner made its deferred restart vanish on
    the next run;
  - an unreadable job state allowed a restart on the single-runner path.

  All three are fixed and covered by drills in RunnerSlice. The source repository
  keeps its own record of them.
- **Green is not proof.** A run's colour does not say which tree it tested or
  how skipped jobs counted. The same organisation built a separate verdict
  tool for that (decision 0004). RunnerSlice's records name the commit and tree
  instead.

## Why not an existing tool

These were compared in October 2026:

- **actions/runner's own `svc.sh`** installs one unit per runner, with no
  resource limits and no shared boundary.
- **Actions Runner Controller and GARM** give ephemeral runners: in Kubernetes
  pods, or in VMs from a provider. They are stronger isolation, but neither
  bounds the rest of a shared host. They are the right choice when untrusted
  code runs.
- **Newer single-host tools** each cover part of the same ground: per-runner
  drop-ins, organisation-scoped ephemeral runners, web dashboards. None
  combined persistent per-repository identities, one shared limit for all
  runners, and a check of the running host's boundary.

## What it cost, and what it saved

- **Nothing was measured as saved.** The equivalent GitHub-hosted ARM64
  minutes for the 30 days above would have been about $49 to $72. That is
  computed at $0.005 per minute, after included minutes that another
  repository had already used. It assumes the hosted runner's speed is 1 to
  1.5 times the self-hosted one, which was never measured.
- **This is a counterfactual, not a bill.** It is not a reason, by itself, to
  run self-hosted runners.
