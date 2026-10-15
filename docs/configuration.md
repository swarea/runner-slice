# Configuration reference

An inventory is a directory, by default `/etc/runner-slice`:

```text
/etc/runner-slice/
  fabric.conf            host-wide policy
  runner-release.conf    the runner release a fresh install starts from
  profiles/<id>.conf     one file per runner
```

## File format

Every file has the same format:

- one `key value` per line;
- `#` starts a comment;
- blank lines are ignored;
- a key that may repeat is written once per value.

Unknown keys are errors, so a misspelling is never silently ignored.

**Ownership.** The directory and everything in it must be owned by root and be
writable only by root. Symlinks are refused. `apply` and `check` run as root
and act on what these files say, so an inventory another account could edit
would hand that account root. A complete working example is in
[`examples/basic`](../examples/basic).

`runner-slice validate` checks all of it offline. It needs no root and no host.

## `fabric.conf`: host policy

### Naming

| Key | Required | Meaning |
|---|---|---|
| `slice` | once | The systemd slice every runner joins. Prefer a single word, such as `ci.slice` or `runners.slice`. A dash in the name is hierarchy: `runner-slice.slice` would live inside an implicit, unlimited `runner.slice`. systemd's own slices (`system.slice`, `user.slice`, `machine.slice` and anything inside them) are refused. |
| `name-prefix` | once | Units are `<prefix>-<id>-runner.service`, or `<prefix>-runner.service` for one runner. Runtime roots are `/var/lib/<prefix>-<id>`. |
| `user-prefix` | once | Runner accounts are `<user-prefix>-<id>` (at most 32 characters in all). |
| `host-label` | once | A runner label every profile on this host must carry, so a workflow can choose this host explicitly. |
| `host-name` | optional | If set, `apply` and `check` refuse to run on a host with another hostname. |

### Slice limits

There are **no defaults**. A number that suits one host starves or
overcommits another.

| Key | Required | Meaning |
|---|---|---|
| `slice-cpu-quota` | once | `CPUQuota` for all runners together, as a percentage of one CPU (`150%` = one and a half CPUs). Must not exceed the host's CPUs. |
| `slice-memory-max` | once | `MemoryMax` for all runners together: bytes, or a size with `K`, `M`, `G` or `T` (base 1024). Must not exceed the host's memory. |
| `slice-memory-high` | optional | `MemoryHigh`: the point where the kernel starts reclaiming from the runners, below `slice-memory-max`. |
| `slice-tasks-max` | once | `TasksMax`: processes and threads for all runners together. |
| `slice-cpu-weight` | optional | `CPUWeight`, from 1 to 10000. It is the runners' share against other slices when the CPU is contended. |
| `slice-ip-deny` | repeatable | An address or prefix no job may reach, for example a cloud metadata address. See [threat-model.md](threat-model.md) for what this does and does not do. |

### Boundaries

| Key | Required | Meaning |
|---|---|---|
| `common-mask` | repeatable; two are mandatory | A path no runner's service may see (`InaccessiblePaths=`). A leading `-` means "if it exists". `-/run/docker.sock` and `-/var/run/docker.sock` must be present: access to that socket is root on the host. Add the directories your other services own. |
| `protected-path` | repeatable | A path no runner **account** may read, even from a login shell outside its service. `check` proves it, and nothing changes permissions for you. List the secret files of your other services here. |

Peer runtime roots are masked automatically. You never list them, and adding a
runner never requires editing another profile.

### Classes

| Key | Required | Meaning |
|---|---|---|
| `sandbox-class` | repeatable | The sandbox classes profiles may use. `baseline` restricts namespaces. `userns` allows them, for jobs that need rootless containers, `unshare` or `bwrap`. |
| `resource-class` | repeatable | The resource classes profiles may use. Today the only class is `shared`: every runner shares the slice. The key exists so that a per-runner class, if one is ever added, is an explicit change to each profile. |

## `runner-release.conf`: the release seed

The runner release a fresh install downloads. Registered runners update
themselves above it. This file is a floor, not a pin.

| Key | Required | Meaning |
|---|---|---|
| `runner-version` | once | For example `2.338.0`. |
| `runner-platform` | once | `linux-x64` or `linux-arm64`. It must match the host's architecture. |
| `runner-archive` | once | `actions-runner-<platform>-<version>.tar.gz` |
| `runner-bytes` | once | The archive's size. |
| `runner-sha256` | once | The archive's SHA-256. The download is refused unless it matches. |
| `runner-url` | once | `https://github.com/actions/runner/releases/download/v<version>/<archive>` |
| `apt-dependency` | repeatable | A package the runner needs on this distribution release. It is installed by name, with no upgrade. |

Take the size and digest from the release page of
[actions/runner](https://github.com/actions/runner/releases), and check them
against your own download.

## `profiles/<id>.conf`: one runner

| Key | Required | Rule |
|---|---|---|
| `profile-id` | once | Equals the file name without `.conf`. It uses lowercase letters, digits and dashes. |
| `runner-repo` | once | `owner/repository` on github.com. |
| `runner-name` | once | The runner's name on GitHub. It is unique on this host, starts with a letter or digit, and is at most 64 characters. |
| `runner-user` | once | `<user-prefix>-<id>` |
| `runner-home` | once | `/home/<runner-user>` |
| `runner-service` | once | `<name-prefix>-<id>-runner.service` |
| `install-root` | once | `/var/lib/<name-prefix>-<id>` |
| `runner-dir` | once | `<install-root>/runner` |
| `work-dir` | once | `<install-root>/work` |
| `runner-label` | at least twice | Must include `host-label` and the profile id. These are the labels registration offers. |
| `runner-pool` | optional | See pools, below. |
| `resource-class` | once | One of the policy's classes. |
| `sandbox-class` | once | One of the policy's classes. |

Every identity (id, name, account, home, unit, root) is unique across the
inventory. Keys that would carry a credential (`*token*`, `*secret*` and so on)
are refused, so the inventory can never hold one.

## Pools: several runners for one repository

Several runners serve one repository as a pool. GitHub gives each queued job
to whichever member is idle.

- **The first member's id is the pool name.** Its `runner-pool` names itself.
  Further members are `<pool>-2` up to `<pool>-9`.
- **Every member** declares the same `runner-repo` and the same
  `runner-pool`, and carries the pool name as a label.
- **Every member offers the same labels**, apart from its own id. Workflows
  select the pool with `runs-on: [self-hosted, <host-label>, <pool>]`.
- **Without `runner-pool`**, two profiles for one repository are refused as an
  accidental copy.

`examples/basic/profiles/web.conf` and `web-2.conf` are a two-member pool.
How to add and retire a member is in [operations.md](operations.md).
