# Contributing

This file is the single source of truth for how work happens in this
repository. Other documents link here rather than restate it.

## Collaboration surface

GitHub only: issues, pull requests and releases.

## Merge policy

**Rebase merge only.** Releases are identified by tags, and each commit is
written to stand on its own, so squashing would replace those commits with one
pull-request title.

Repository settings, applied through the API on 2026-10-15 and checked
afterwards:

- rebase merging only, with squash and merge commits disabled;
- head branches deleted automatically after merge;
- auto-merge disabled.

**Not yet enforced.** While the repository is private on the organisation's
Free plan, GitHub offers no branch protection and no rulesets. So the following
are procedure, not settings:

- the `gate` check must pass before a merge;
- no force push to `main`;
- no deletion of `main`.

When the repository becomes public they become settings: `gate` required,
linear history required, force pushes and deletion refused. Administrators
will not be included, so that an outage of GitHub Actions cannot block a
release; the owner can override.

**No required review.** This is a one-person repository, so a required review
would stop every merge. Every merge is an explicit owner decision. A green
`gate` is necessary, never sufficient, and nothing merges automatically.

## Branches

- `main` is the only long-lived branch.
- Work branches are named `<type>/<slug>`, for example `fix/retire-guard`.
- A pull request may be stacked on another. When the lower one is merged by
  rebase, the upper branch is moved onto the new `main` as a new branch.
  Pushed branches are never force-pushed.

## Commits

```
<type>: <lowercase imperative english summary>    no scope, no period

A short paragraph on why the change was needed.

- what materially changed
- compatibility or behaviour impact, if any
```

- **Types:** `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`, `test`, `ci`,
  `build`. They follow the organisation's
  [commit format](https://github.com/swarea/.github/blob/main/docs/commit-format.md).
- **One kind of change per commit.**
- **Forbidden:** emoji, `Co-Authored-By` for anyone who is not a person who
  wrote the change, `Generated with`, AI-tool promotion, and verification logs.
  Verification logs go in the pull request.

## Pull requests

`.github/PULL_REQUEST_TEMPLATE.md` lists the sections every pull request
fills in. Two rules matter most.

- **List only checks that were actually run, with their results.** A check
  that did not run is reported as SKIPPED or BLOCKED, never as passed.
- **State the evidence level reached** (see
  [docs/verification.md](docs/verification.md)). A green `gate` is
  SYNTHETICALLY TESTED at most.

## Verification

```sh
bash tests/run.sh          # shellcheck, then every drill
```

`tests/run.sh` is the one entry point, and CI runs exactly it. It needs
`shellcheck`; set `SHELLCHECK=/path/to/shellcheck` if it is not on `PATH`.
It refuses to run as root, because several drills prove refusals of an
ordinary account.

A change to anything that runs as root must come with a drill case that fails
without it. The practice is to remove each new guard by hand and confirm a
drill case fails.

## CI and self-hosted runners

The `check` workflow runs on GitHub-hosted runners only, with a read-only
token. Code from a pull request never runs on a host RunnerSlice manages.
Dogfood runs, where RunnerSlice's own runners test RunnerSlice, happen in a
separate private repository on commits the owner has approved. See
[docs/verification.md](docs/verification.md).

## Security reports

See [SECURITY.md](SECURITY.md). Vulnerabilities are never reported in public
issues.
