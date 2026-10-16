# Compatibility

This is the only list of supported environments. It shows only what has
actually been verified, and at what level ([verification.md](verification.md)).
"Expected to work" is not a support level.

## Hosts

| Distribution | Architecture | systemd | Status |
|---|---|---|---|
| Ubuntu 24.04 | x86_64 | 255 | **Not verified.** Preflight accepts it; no x86_64 host has run RunnerSlice. |
| Ubuntu 24.04 | aarch64 | 255 | **Verified** on a disposable VM (Lima, Apple Virtualization), at RUNTIME VERIFIED and REBOOT VERIFIED. See [acceptance/2026-10-arm64.md](acceptance/2026-10-arm64.md). The lifecycle was run with two real GitHub runners, ending in deregistration and retirement. One VM; no other aarch64 host verified. |
| Ubuntu 22.04 | aarch64 | 249 | The code RunnerSlice was extracted from has run here in production (see [field-report.md](field-report.md)). **This code** has not been run there. Not supported. |
| Any other distribution | | | Refused by preflight. |

## systemd: accepted is not supported

Two ranges differ, on purpose, and neither stands in for the other.

| | Versions | Meaning |
|---|---|---|
| **Supported** | 255 | Verified on a real host by the acceptance above. |
| **Accepted, unverified** | 249–254, and 256 or later | Preflight lets these through, and warns, naming the version as unverified. Nothing about them has been observed on a host. |
| **Refused** | older than 249 | Preflight refuses. |

Why the code accepts more than is supported. The floor of 249 is what the
units rely on: `ProtectHome=tmpfs` with `BindPaths`, and a slice's
`IPAddressDeny` merged into every unit inside it. The one value `check` was
found to depend on in a version-specific way is how `systemctl show` prints
`RestrictNamespaces` (`yes`, `no`, or a list). That printing code
(`src/shared/bus-print-properties.c`) was read, not run, in the v249, v252
and v255 sources and is the same in all three. That is a source review. It
is not verification, and it covers only that one property. Raising the floor
to 255 would refuse hosts that nothing shows are broken. Calling them
supported would claim what nothing shows works. So they are accepted with a
warning, and only 255 is listed as supported.

Preflight refuses:

- a distribution other than Ubuntu;
- systemd older than 249 (249–254 and 256 or later pass with a warning that
  they are unverified);
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
