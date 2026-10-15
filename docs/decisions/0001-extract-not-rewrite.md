# 0001: Extract the existing fabric instead of rewriting it

Status: accepted (working)

## Context

A private infrastructure repository already contains a working runner fabric:

- about 2,200 lines of Bash covering validation, rendering, converge, check
  and status;
- about 3,700 lines of drills that exercise that code against fixtures, as
  opposed to mocks of it.

It has run real repositories for weeks. Most of its behaviour is not specific
to the host. The coupling is a short list of names, paths and constants.

## Decision

Extract the code, keep Bash and systemd, and remove the coupling by moving each
host-specific value into the declared policy, or by deleting it if it was one
host's policy. Port the drills along with the code, against fictional example
inventories.

## Alternatives refused

- **Rewrite in Go or Rust.**
  - It would discard the drills, which encode most of the failure knowledge.
  - It would add a toolchain and release pipeline for a tool that shells out
    to `systemctl`, `install` and `useradd` anyway.
- **Build on ARC or GARM.**
  - Both solve ephemeral autoscaling well.
  - Neither bounds the rest of a shared host. The shared slice and the
    runtime checks are the part this project exists for.
- **A Python CLI around the Bash.** It would add a dependency layer without
  removing a problem the shell code has.

## Consequences

- **Supported hosts.** Only systemd hosts with Bash 4+ are supported.
- **Re-earned evidence.** Evidence from the source host is history, not
  evidence for this code. Every level is earned again.
