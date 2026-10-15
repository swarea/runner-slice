# 0004: The CI evidence verdict stays out of RunnerSlice for now

Status: accepted (2026-10-15)

## Context

The infrastructure repository RunnerSlice came from also has a read-only tool
that judges a commit from GitHub's evidence. It asks:

- which tree each run actually tested;
- how skipped jobs count;
- whether the policy that judged it came from a trusted branch.

It answers "what did CI actually prove about this commit?". There it has
turned a green-but-wrong result into a refusal, and it is valuable.

## Options

1. **An optional RunnerSlice command.**
   - It would sit beside the tool that hosts the runners whose results it
     judges.
   - But it needs its own policy file, its own trust root on the default
     branch and GitHub API access. None of that relates to managing runners.
   - It would also widen what a RunnerSlice release must verify, before the
     core lifecycle has been verified on a single real host.
2. **A separate small project, later.**
   - It is useful to anyone on GitHub Actions, self-hosted or not. Its users
     need not be RunnerSlice's users.
   - It needs its own generalisation: its policy and judge are written for
     one repository's workflow.
3. **Stay in the infrastructure repository.**
   - That is where it is used and maintained today.

## Decision

For RunnerSlice v1, option 3, with option 2 recorded as a candidate:

- the tool stays where it is, unchanged;
- RunnerSlice neither depends on it nor includes it;
- whether to generalise it into its own project is decided on its own merits,
  after RunnerSlice's lifecycle has been verified. It is not forgotten.

## Consequences

- RunnerSlice's verification records name the commit and tree tested by hand,
  in each pull request and in the acceptance record, instead of relying on the
  tool.
- If the tool is extracted later, RunnerSlice's dogfood runs are a natural
  first user. They would change nothing in RunnerSlice itself.
