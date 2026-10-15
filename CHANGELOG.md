# Changelog

Entries are written for someone upgrading: what they have to do, and what will
behave differently. Versions follow the evidence, as set out in
[docs/contract.md](docs/contract.md), not a calendar.

## Unreleased

There is no release yet. Everything below is SYNTHETICALLY TESTED only. None
of it has run on a real host.

- **Declarative inventory:**
  - one policy file, one release seed and one profile per runner;
  - pools of several runners for one repository;
  - slice limits that must be declared, with no defaults.
- **Commands:** `runner-slice validate`, `render`, `plan`, `apply`, `retire`,
  `check`, `status` and `version`.
- **Apply:**
  - never restarts a runner whose job is running or whose state is unknown;
  - never replaces units, nor adopts or removes accounts, that RunnerSlice
    did not create;
  - completes an interrupted unpack;
  - refuses to start a runner registered as something its profile does not
    say.
- **Check** proves the boundary on the running host:
  - installed units against the rendering;
  - effective limits and the deny list;
  - mounts in the service's own namespace, and the home namespace;
  - file permissions from the runner account's side;
  - the registration's identity.
- **A reproducible release archive with a checksum**, whose own tests run
  after unpacking.
- **Fixes from the pre-integration security review:**
  - the runner's version is read as data, and the runner is never executed by
    `apply` or `check`;
  - a registered runner is never unpacked into, and a first unpack goes into
    a directory root has just created;
  - the registration token goes through the environment, not the command
    line;
  - runtime roots, groups and homes that RunnerSlice did not create are
    neither adopted nor removed;
  - retirement removes nothing unless every precondition holds;
  - check fails when an access test cannot run;
  - masks are recognised by the mount's root only;
  - `TMPDIR` is ignored, and paths are resolved physically.
