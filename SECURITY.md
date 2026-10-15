# Security policy

RunnerSlice runs as root and decides how far CI jobs reach on a shared host.
A flaw in it can turn a CI job into access to the rest of that host. The full
model is in [docs/threat-model.md](docs/threat-model.md). This file says how to
report a problem and what counts as one.

## Reporting a vulnerability

Report it privately, through GitHub's private vulnerability reporting for this
repository (**Security → Report a vulnerability**). Never use a public issue.
Include the RunnerSlice commit or version, the host's distribution and systemd
version, and the smallest inventory that shows the problem.

While the repository is private, that form is not available. Report to the
maintainer directly through GitHub.

Expect a first reply within a week. There is no bounty and no formal SLA. A fix
is released together with a note that says what was affected and what an
operator has to do.

## Supported versions

There is no release yet. Once there is, only the latest release receives
fixes.

## In scope

Any way, with RunnerSlice configured as documented, for:

- a job on one runner to read or write another runner's runtime root, home or
  credentials;
- a job to reach a path the inventory masks, a `protected-path`, or the Docker
  socket;
- a job to escape the slice's CPU, memory or task limits;
- an unprivileged account to change what RunnerSlice runs as root, or the
  configuration it acts on;
- `runner-slice apply` or `retire` to change or remove a unit, account or
  directory that RunnerSlice did not create;
- `runner-slice check` to report a boundary as intact when it is not;
- RunnerSlice to write, print or log a registration token or `.credentials`.

## Out of scope

These are documented limits, not vulnerabilities:

- **Code that a repository's own workflow runs as its runner account.** That
  is what a runner is for.
- **Kernel exploits, and anything else that defeats Unix permissions or systemd
  sandboxing in general.** RunnerSlice is not a VM boundary.
- **Running untrusted pull requests from strangers on a persistent runner.**
  This is unsupported; see the threat model.
- **Network access a job has to anything other than declared
  `slice-ip-deny` entries.** RunnerSlice is not a network policy.
