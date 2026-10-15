# 0003: The project is named RunnerSlice

Status: accepted (owner decision, 2026-10-15)

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
| Repository, archive, command, configuration directory | `runnerslice` (`swarea/runnerslice`, `runnerslice-<version>.tar.gz`, `/etc/runnerslice`) |
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
