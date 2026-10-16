# RunnerSlice

A systemd-native manager for self-hosted GitHub Actions runners.

RunnerSlice runs persistent, repository-scoped GitHub Actions runners on a
Linux host you already operate. Each runner has its own Unix account and
runtime root, and they all share one resource-limited systemd slice. Changes
are applied without interrupting a running job. A read-only check proves, on
the running host, that the boundary and limits are what you declared.

It is Bash and systemd. It has no daemon, no database, no Kubernetes and no
web server.

> **Status: pre-release (0.1.0-dev).**
>
> - Every behaviour described here is exercised by drills against a fixture
>   host. That is SYNTHETICALLY TESTED.
> - The full lifecycle has also run on **one real host**: an Ubuntu 24.04
>   aarch64 VM with two real GitHub runners. It went from install to
>   registration, jobs, pool, busy guard, reboot, deregistration and
>   retirement ([docs/acceptance/2026-10-arm64.md](docs/acceptance/2026-10-arm64.md)).
> - RunnerSlice's own drills ran there as GitHub Actions jobs, on runners
>   RunnerSlice installed and managed.
> - **Not verified:** x86_64, other distributions, and GitHub-hosted CI for
>   this repository. GitHub-hosted CI is currently blocked by the
>   organisation's billing.
> - No release exists. Use a machine you can afford to rebuild.

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

## How it works

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
