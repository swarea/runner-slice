# 0002: The baseline sandbox restricts namespaces

Status: accepted (working)

## Context

The source fabric had two sandbox classes:

- `baseline` emitted no `RestrictNamespaces=` line. It deliberately preserved
  the systemd default, unrestricted, so that a migration would not tighten
  anything silently.
- `userns` emitted `RestrictNamespaces=no` explicitly, for jobs that need user
  namespaces (for example to run an emulated userland under `unshare`).

The two classes therefore behaved the same, and the name `baseline` suggested
a restriction it did not have.

## Decision

- **`baseline`** renders `RestrictNamespaces=yes`.
- **`userns`** remains the explicit opt-in. It renders `RestrictNamespaces=no`
  and is documented as widening the kernel attack surface.

## Consequences

- **Jobs that fail on `baseline`:** any job that creates namespaces. That
  covers rootless containers, `unshare`, `bwrap` and some test harnesses. They
  need `userns`, chosen per profile.
- **Not yet verified:** that the GitHub runner itself works under
  `RestrictNamespaces=yes`. This is checked on the test VM before Alpha.
