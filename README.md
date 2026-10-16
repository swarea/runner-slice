<div align="center">

<img src="docs/assets/mark.png" alt="" width="96" height="96">

# RunnerSlice

**A systemd-native manager for self-hosted GitHub Actions runners.**

[Installation](docs/installation.md) ·
[Operations](docs/operations.md) ·
[Threat model](docs/threat-model.md) ·
[Verification](docs/verification.md)

[![check](https://github.com/swarea/runner-slice/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/swarea/runner-slice/actions/workflows/check.yml?query=branch%3Amain)
![status: public alpha](https://img.shields.io/badge/status-public%20alpha-0f6b7d)
[![MIT](https://img.shields.io/badge/licence-MIT-1c1e22)](LICENSE)

</div>

RunnerSlice runs persistent, repository-scoped GitHub Actions runners on a
Linux host you already operate. Each runner has its own Unix account and
runtime root, and they all share one resource-limited systemd slice. Changes
are applied without interrupting a running job. A read-only check proves, on
the running host, that the boundary and limits are what you declared.

It is Bash and systemd. It has no daemon, no database, no Kubernetes and no
web server.

> **Status: public alpha (0.1.0-dev). Development has ended at this stage.
> There is no release or tag.**
>
> - **Every push and pull request** runs shellcheck and every drill on
>   GitHub-hosted runners (the `check` workflow). The drills exercise each
>   behaviour against a fixture host. That is SYNTHETICALLY TESTED.
> - **The full lifecycle has run on one real host:** an Ubuntu 24.04 aarch64
>   VM with systemd 255 and two real GitHub runners. It went from install to
>   registration, jobs, pool, busy guard, the slice limits, reboot,
>   deregistration, retirement and recovery from a retirement that failed
>   part-way ([docs/acceptance/2026-10-arm64.md](docs/acceptance/2026-10-arm64.md)).
> - **RunnerSlice's own drills ran there as GitHub Actions jobs**, on runners
>   RunnerSlice installed and managed.
> - **Not verified:**
>   - x86_64, and any systemd other than 255;
>   - a runner's self-update;
>   - `runner-slice status` with an authenticated `gh`;
>   - an unknown job state and a misregistration on a real host.
>
> Use a machine you can afford to rebuild.

## Why

GitHub's own runner can install itself as a service, but that service has no
resource limits and no boundary towards the rest of the host. If you run CI
on a server that also runs other things, you need answers to these:

- How much of the machine can CI take?
- Can a job of one repository read another repository's checkout or
  credentials?
- Can a job reach the Docker socket, other services' files, or the cloud
  instance's metadata?
- Can I change any of this without killing a running job?
- How do I know the running host still matches what I declared?

RunnerSlice's answer:

- One slice with declared CPU, memory and task limits for all runners
  together.
- A Unix account per runner, with no supplementary groups.
- Every other runner's runtime root, all human homes, the Docker socket and
  the paths you name, hidden from each runner's service.
- An optional deny list for addresses such as a metadata service.
- An apply that refuses to restart a runner while a job runs, or while it
  cannot tell.
- A check that reads the live mount table, systemd's effective values and
  the account's actual permissions, instead of repeating the configuration
  back to you.

## Who it is for

**For** an operator who:

- already runs a Linux server with spare capacity;
- wants persistent runners for repositories they trust;
- needs a hard ceiling on what CI may take;
- wants to verify that ceiling.

**Not for:**

- **Public repositories that run pull requests from strangers.** A persistent
  self-hosted runner on a shared host is not safe for that, and RunnerSlice
  does not change it. Use ephemeral runners: GitHub-hosted runners, Actions
  Runner Controller, or GARM with VMs.
- **Isolation as strong as a VM.** Runners share the host's kernel and
  network.
- **Autoscaling, many hosts, organisation-level runners.**

The full security model is in [docs/threat-model.md](docs/threat-model.md).

## Compared with other tools

| | Isolation | Bounds the rest of the host | Persistent per-repository runners |
|---|---|---|---|
| `actions/runner`'s `svc.sh` | none beyond the account you choose | no | yes, one unit each, no limits |
| Actions Runner Controller, GARM | pods or VMs, ephemeral | not on a shared host | no: ephemeral by design |
| **RunnerSlice** | a Unix account and systemd sandbox per runner | yes: one slice with declared limits, plus masks | yes |

Choose ephemeral runners when untrusted code runs. Choose RunnerSlice when
you trust the repositories, want to reuse a server you already operate, and
need to bound and verify what CI can take from it.

## How it works

```text
              one host
 ┌─────────────────────────────────────────────────┐
 │ ci.slice   CPUQuota, MemoryMax, TasksMax        │
 │            IPAddressDeny (optional)             │
 │ ┌───────────────────┐  ┌───────────────────┐    │
 │ │ runner-app        │  │ runner-web        │    │
 │ │ own account, root │  │ own account, root │    │
 │ │ peers' roots, all │  │ peers' roots, all │    │
 │ │ homes, Docker     │  │ homes, Docker     │    │
 │ │ socket: masked    │  │ socket: masked    │    │
 │ └───────────────────┘  └───────────────────┘    │
 └─────────────────────────────────────────────────┘
   plan / apply / retire change it;  check reads it back
```

```text
/etc/runner-slice/fabric.conf           slice limits, prefixes, masks for the whole host
/etc/runner-slice/runner-release.conf   the actions/runner release to install, by SHA-256
/etc/runner-slice/profiles/app.conf     one runner: repository, name, account, labels
```

```sh
runner-slice validate          # offline: identities unique, pools consistent, no secrets
sudo runner-slice plan         # what apply would change; changes nothing
sudo runner-slice apply app    # account, directories, release, units; stops at registration
#   ... a person registers the runner with a one-hour token (the command is printed) ...
sudo runner-slice apply app    # confirms the registration, enables and starts the service
sudo runner-slice check        # proves the boundary and limits on the running host
runner-slice status            # GitHub's view: online, busy, local service state
sudo runner-slice retire app   # drain, stop, deregister, remove; one safe step per run
```

Several runners for one repository form a **pool**. Add a profile, apply the
fleet with the runners idle, and register the new runner.

## Supported hosts

Ubuntu with systemd 249 or later, cgroup v2 and x86_64 or aarch64 is what
preflight accepts. What is supported is narrower: **verified so far, Ubuntu
24.04 on aarch64 (systemd 255), on one VM.** Preflight warns on any systemd
other than 255. [docs/compatibility.md](docs/compatibility.md) is the only list of
what has been verified.

## Getting started

1. Read [Installation](docs/installation.md): requirements, and how to build
   the archive from a commit and install it. No release is published.
2. Write the inventory ([Configuration](docs/configuration.md)), then follow
   [Operations](docs/operations.md) from `plan` to the first registered runner.
3. Run `sudo runner-slice check` after every change and every reboot.

## Documentation

| | |
|---|---|
| [Installation](docs/installation.md) | requirements, the release archive, install and remove |
| [Configuration](docs/configuration.md) | every key, pools |
| [Operations](docs/operations.md) | first runner, adding runners, changes, retirement, recovery, exit codes |
| [Architecture](docs/architecture.md) | the parts and what each owns |
| [Threat model](docs/threat-model.md) | what is protected, how, and what is not |
| [Verification](docs/verification.md) | evidence levels, drills, lifecycle acceptance, dogfooding |
| [Compatibility](docs/compatibility.md) | verified hosts and providers |
| [Field report](docs/field-report.md) | what the production predecessor taught, with numbers |
| [Product contract](docs/contract.md) | scope, exclusions, release criteria |
| [Decisions](docs/decisions) | the reasons behind the design |

## Origin

RunnerSlice was extracted from a runner fabric that runs six runners for five
repositories on a 4-core ARM64 cloud host, beside production services. The
extraction kept that fabric's drills and changed its defaults; see the
[field report](docs/field-report.md). That history explains the design. It is
not evidence for this code.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md), and report vulnerabilities as described
in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)

GitHub and GitHub Actions are trademarks of GitHub, Inc. RunnerSlice is not
affiliated with or endorsed by GitHub.
