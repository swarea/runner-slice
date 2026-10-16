# Threat model

RunnerSlice runs persistent GitHub Actions runners for several repositories on
one Linux host that also does other work. This document says:

- what it protects;
- what it does not protect;
- which mechanism each protection rests on;
- how `runner-slice check` proves that mechanism on the running host.

Every claim here is SYNTHETICALLY TESTED unless it says otherwise. Nothing in
this document has yet been observed on a real host running this code. The
evidence levels are defined in [verification.md](verification.md).

## Who is trusted

| Party | Trust |
|---|---|
| The operator who writes the inventory and runs `apply` as root | Fully trusted. |
| Each repository whose runner RunnerSlice installs, and everyone who can push to it or open a pull request whose workflow runs | Trusted to run code **as that runner's account**, and nothing more. |
| GitHub | Trusted to deliver jobs only to the runners registered to a repository. |
| Other users and services on the host | Not trusted by the runners, and not given anything by them. |

The supported use is CI for repositories the operator trusts. A public
repository that runs workflows for pull requests from strangers must not use a
persistent self-hosted runner on a shared host. That rule is GitHub's own
advice too.

If you need that, use ephemeral VM-based runners: GitHub-hosted runners,
Actions Runner Controller, or GARM with a VM provider.

## What is protected, and how

| Asset | Mechanism | How `check` proves it |
|---|---|---|
| Other runners' runtime roots | Each runner's unit masks every peer's `/var/lib/<prefix>-<id>`, derived from the whole inventory. Roots are `root:<account> 0750`. | Each peer root is resolved in the live mount table of the runner's own process. Owner and mode are checked. |
| Other runners' homes, and every human home | `ProtectHome=tmpfs` with `BindPaths` of the runner's own home | The live mount table shows a tmpfs `/home` with only the runner's own real home bound beneath it. |
| Registration credentials | Owned by each runner's account, mode 600; RunnerSlice never opens `.credentials`. | Owner and mode are checked. The registration's repository, name and work folder are compared with the profile. |
| Paths the operator declares (`common-mask`) | `InaccessiblePaths=` in every runner unit | The live mount table, including symlinked aliases and masked parent directories. |
| Secrets the operator declares (`protected-path`) | Unix permissions, which the operator sets | Run as the runner account, `test -r` must fail. This covers a login shell too, outside the service. |
| The Docker socket | Runner accounts hold no supplementary group. The socket is masked too. | Group membership is checked; run as the account, `test -w` on the socket must fail. |
| Everything else on the host: CPU, memory and process count | One slice for all runners with declared `CPUQuota`, `MemoryMax`, optional `MemoryHigh`, and `TasksMax` | The installed slice is compared with the rendering. systemd's effective values are compared with the declaration. |
| Declared network destinations (`slice-ip-deny`) | `IPAddressDeny=` on the slice. systemd merges it into every runner's own IP filter. | systemd's effective deny list includes each entry. No allow list exists on the runner, the slice or any slice above it. |
| What root runs and reads | Preflight refuses a configuration or tool tree that root does not own exclusively: other owners, group- or world-writable entries, symlinks, writable parent directories. | This is checked before every apply and check. |
| Units, accounts and directories RunnerSlice did not create | Units carry a first-line marker. Runtime roots carry a root-owned marker naming their profile. Accounts are adopted only if they are system accounts with the expected home. A group or home that predates its account is never adopted. | Apply stops before creating anything next to a foreign unit or directory. Retirement checks every precondition first, and removes nothing unless all hold. A group is removed only when it is the account's own, unused primary group, read before the account goes. |
| Running jobs | No unit is replaced and no runner is restarted while a job is running or its state is unknown. | The job state is read from the service's cgroup, whose path comes from systemd, and from `/proc`. |

Every runner unit also sets:

- `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectSystem=full`;
- `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`,
  `ProtectClock`;
- `RestrictSUIDSGID`, `RestrictRealtime`, `LockPersonality`;
- `UMask=0027`.

The `baseline` sandbox also sets `RestrictNamespaces=yes`. Profiles whose jobs
need namespaces opt into `userns` (decision 0002).

## What is not protected

- **The kernel.** Every runner shares it with the host. A kernel exploit
  defeats every mechanism above.
- **The network.** Apart from `slice-ip-deny` entries, a job can reach
  whatever the host can reach: the internet, other machines, and services
  listening on loopback. A loopback service without authentication is
  reachable from every job. Put such services behind authentication, or
  declare their addresses.
- **Cloud instance metadata.** Whether a job can read the instance's
  identity, credentials or user data depends on the provider and on what the
  operator declares. RunnerSlice declares nothing by default.
  - OCI, AWS and GCP all serve metadata at `169.254.169.254`. AWS also serves
    it at `fd00:ec2::254` when IPv6 is on.
  - A `slice-ip-deny` entry closes one address. It does not cover a metadata
    service reached any other way, and it is not a network policy. Whether a
    cloud's DNS resolver shares that address, and whether denying it breaks
    name resolution for jobs, must be checked on that provider.
  - Only what has been verified on a provider is listed in
    [compatibility.md](compatibility.md).
- **A job's own repository.** A job can do anything its runner account can,
  for as long as the job runs, and can leave files in its runtime root for
  later jobs of the same repository. Persistent runners are not clean between
  jobs.
- **Secrets the host leaves world-readable.** Masks cover the runner's
  service. Only `protected-path` entries are checked from the account's side.
  Anything else world-readable can be read by the runner account.
- **Availability under a full slice.** The limits keep runners from taking
  more than declared. Inside the slice, runners compete, and a job may be
  throttled or killed by the memory limit.
- **Other runners on the same host.** Runners installed by GitHub's own
  `svc.sh` are outside the slice. Preflight reports them and changes nothing.

## How the check avoids repeating the declaration

A check that read its expectations from the unit it checks could not notice
the unit being wrong. So `runner-slice check` derives every expectation from the
inventory and the library, then reads the host:

- **Installed units** are compared with a fresh rendering of the inventory.
  Drop-ins, which would add a second answer, fail the check.
- **Effective values** come from systemd (`systemctl show`), not from unit
  text.
- **Masks and home isolation** come from the running service's own mount
  table, not from `InaccessiblePaths=` lines.
- **Permissions** are tested as the runner account.
- **Anything that cannot be read is a failure.** That includes a stopped
  service, an unreadable mount table, an unreadable registration, and an
  unknown CPU quota format.

The fixtures in the drills encode what systemd is expected to print. Each of
those assumptions is listed in [verification.md](verification.md) and has to be
observed on a real host before it counts.

## Handling of registration

- Registration needs a token valid for one hour. RunnerSlice never asks for
  it, stores it or prints it. It prints the command for a person to run.
  That command passes the token through the environment, never as an
  argument: sudo logs command lines, and `ps` shows them to every account.
- RunnerSlice never runs what the runner account can write. The installed
  version is read from the runner's dependency manifest as data. Files the
  runner writes are opened without following symlinks, only if they are
  small regular files.
- A registered runner's directory is never unpacked into again. A first
  unpack goes into a directory root has just created, closed to the runner
  account until it is handed over.
- `.runner` holds the runner's name, repository and work folder, and no
  credential. RunnerSlice reads it to refuse a runner registered as something
  else.
- `.credentials` and `.credentials_rsaparams` are never opened.
