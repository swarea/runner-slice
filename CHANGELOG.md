# Changelog

Entries are written for someone upgrading: what they have to do, and what will
behave differently. Versions follow the evidence, as set out in
[docs/contract.md](docs/contract.md), not a calendar.

## Unreleased (public alpha)

There is no release or tag yet. Everything below is SYNTHETICALLY TESTED by
the drills, which run on GitHub-hosted CI for every change. The lifecycle has
also been RUNTIME VERIFIED and REBOOT VERIFIED on one Ubuntu 24.04 aarch64 host
with systemd 255 ([docs/acceptance/2026-10-arm64.md](docs/acceptance/2026-10-arm64.md)).
Nothing has run on x86_64.

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
- **Fixes from the real ARM64 host:**
  - the release archive carries 0644/0755 modes, so preflight accepts the
    unpacked tree;
  - `check` reads `RestrictNamespaces=yes` and `no` as systemd prints them;
  - the printed registration never uses `--replace`, and runs `config.sh` in
    its own directory;
  - `config.sh remove` is printed without `--unattended`, which it rejects.
- **Fixes from the post-acceptance review (#18):**
  - leftover processes are found by every uid in `/proc`, and an unreadable
    process table refuses retirement;
  - retirement removes the account, then the runtime root with its marker
    last, then the unit, so a run that fails part-way can be finished by
    another;
  - only the account's own unused group is removed, and a leftover home or
    group is reported by name;
  - runner-written files are read without following any symlink below the
    runner directory; any parse failure is "cannot tell";
  - the printed token commands run in a subshell;
  - the runner directory stays 0700 for the whole unpack.
- **Behaviour an operator will notice:**
  - preflight warns on any systemd other than 255;
  - `retire` exits 1 when it leaves something behind, and names it.
