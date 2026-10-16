# Compatibility

This is the only list of supported environments. It shows only what has
actually been verified, and at what level ([verification.md](verification.md)).
"Expected to work" is not a support level.

## Hosts

| Distribution | Architecture | systemd | Status |
|---|---|---|---|
| Ubuntu 24.04 | x86_64 | 255 | **Planned** for the first verification VM. Not yet verified. |
| Ubuntu 24.04 | aarch64 | 255 | **Verified** on a disposable VM (Lima, Apple Virtualization), at RUNTIME VERIFIED and REBOOT VERIFIED. See [acceptance/2026-10-arm64.md](acceptance/2026-10-arm64.md). The lifecycle was run with two real GitHub runners, ending in deregistration and retirement. One VM; no other aarch64 host verified. |
| Ubuntu 22.04 | aarch64 | 249 | The code RunnerSlice was extracted from has run here in production (see [field-report.md](field-report.md)). **This code** has not been run there. |
| Any other distribution | | | Refused by preflight. |

Preflight refuses:

- a distribution other than Ubuntu;
- systemd older than 249;
- a host without the cgroup v2 unified hierarchy, or without its `cpu`,
  `memory` or `pids` controller;
- an architecture other than the release seed's.

## Cloud providers

RunnerSlice has nothing provider-specific in it. The one thing that differs
is whether jobs can reach the instance metadata service. Deciding that is the
operator's job, through `slice-ip-deny`; see [threat-model.md](threat-model.md).

| Provider | Metadata address | `slice-ip-deny` verified to block it without breaking DNS |
|---|---|---|
| Oracle Cloud (OCI) | `169.254.169.254` | Not with this code. With the source code, on Ubuntu 22.04 / systemd 249, a slice-level deny was deployed and observed in each runner's IP filter ([field-report.md](field-report.md)). |
| AWS EC2 | `169.254.169.254`, and `fd00:ec2::254` with IPv6 | Not verified. |
| Google Compute Engine | `169.254.169.254` | Not verified. |
| Bare metal, home servers | none | Not applicable. |

## GitHub

- **Repository-scoped runners** only. Organisation and enterprise runners are
  out of scope for v1.
- **The runner release** is taken from `actions/runner`, using the
  `linux-x64` and `linux-arm64` archives. Registered runners update
  themselves.
- **`runner-slice status`** needs `gh` with read access to the repository's
  runners.
