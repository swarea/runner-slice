# 0003: The project is named RunnerSlice

Status: accepted (owner decision, 2026-10-15), amended the same day

## Context

The project began under the working title "runner-fabric". That title had
three problems:

- The organisation has an unrelated private project with "fabric" in its
  name, which also runs and isolates things.
- "Fabric" is a well-known Python tool, and also part of other product
  names.
- It suggests orchestration across many hosts, which this project
  deliberately does not do.

These names were considered and set aside: RunnerKeep, Runner Fabric,
Buildcell, OCI-CI, bounded-ci, host-ci, runner-tenants, runnerd, runner-fleet
and runnerctl.

- OCI-CI collides with both Oracle Cloud Infrastructure and the Open Container
  Initiative, and reads as tied to one cloud.
- runnerd, runner-fleet and runnerctl are already used by active projects.
- runner-tenants claims an isolation the tool cannot give.

## Decision

The product is **RunnerSlice**. The shared systemd slice is the mechanism that
makes it useful on a shared host, and the name says so without naming a cloud
or GitHub.

| Use | Spelling |
|---|---|
| Product name in prose | RunnerSlice |
| Repository, command, archive, configuration directory | `runner-slice` (`swarea/runner-slice`, `runner-slice`, `runner-slice-<version>.tar.gz`, `/etc/runner-slice`) |
| One-line description | A systemd-native manager for self-hosted GitHub Actions runners. |
| Unit descriptions | name RunnerSlice, so a unit on a host can be traced to it |

Inside the code, "fabric" remains the name of the declarative inventory layer:
`fabric.conf`, `fabric/fabric-lib.sh` and the `fabric_*` functions. It is an
architecture term, not a second product name, so it is not renamed. Renaming it
would churn every file and drill for no change in behaviour.

GitHub's trademark policy rules out "GitHub" and "Actions" as part of the name.
They appear only in descriptions ("for GitHub Actions").

## Consequences

- The working title is removed from user-facing text. Decision records keep
  it where they describe history.
- No formal trademark search was done. The name was checked for collisions
  on GitHub, PyPI, npm, crates.io and Debian on 2026-10-15, and none was found.

## Amendment (2026-10-15): `runner-slice`, with a hyphen

The repository and command were first spelled `runnerslice`. The owner had
intended `runner-slice` from the start, and corrected it. The product name
stays RunnerSlice. Everything a person types or a file is named after is now
`runner-slice`:

- the repository, `swarea/runner-slice`, renamed with GitHub's rename so
  that its history, pull requests and settings were kept;
- the command `bin/runner-slice`;
- the default configuration directory `/etc/runner-slice`;
- the seed marker `.runner-slice-seeded`;
- release archives, `runner-slice-<version>.tar.gz`.

The earlier spelling remains in commits that predate the change.

### The systemd slice is named separately

The hyphenated name is **not** a good name for the runners' slice:

- In a slice unit's name, a dash is hierarchy. `runner-slice.slice` would
  live inside `runner.slice`. systemd creates that parent implicitly, with no
  limits of its own, and any other unit could join it.
- The ceiling is meant to sit directly under the root, beside `system.slice`
  and `user.slice`.

So the slice stays the operator's declaration (`slice` in `fabric.conf`). The
documentation recommends a single-word name such as `ci.slice` or
`runners.slice`. Nested names keep working: the check finds every ancestor
and refuses an allow list on any of them. But they are a deliberate choice,
not the default.
