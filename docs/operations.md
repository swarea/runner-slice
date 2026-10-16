# Operations

> **Status: pre-release.** The lifecycle below was run end to end on one real
> Ubuntu 24.04 aarch64 host with two GitHub runners
> ([acceptance/2026-10-arm64.md](acceptance/2026-10-arm64.md)). Unknown job state
> and misregistration are exercised by drills only.

The command forms used throughout:

```text
runner-slice [--config DIR] validate                 offline, any user
runner-slice [--config DIR] plan    [PROFILE]        as root; changes nothing
runner-slice [--config DIR] apply   [PROFILE]        as root
runner-slice [--config DIR] retire  PROFILE [--check] as root
runner-slice [--config DIR] check   [PROFILE]        as root; changes nothing
runner-slice [--config DIR] status  [PROFILE]        as an ordinary user with gh
```

Without a profile, `plan`, `apply`, `check` and `status` act on every profile.

## Exit codes

| Code | `plan` / `apply` / `retire` | `check` | `status` |
|---|---|---|---|
| 0 | Converged. For `plan`, nothing to do. | The host matches the declaration. | Every runner is online and running. |
| 1 | Failed, refused, or something is outstanding, such as a registration or a deferred unit. For `plan`, there is work to do. | Something differs, or could not be read. | A runner is offline or not running, or GitHub's answer could not be trusted. |
| 2 | Usage error. | Usage error. | Usage error. |
| 10 | `retire` only: waiting for deregistration. | | |

Every `apply` line is one of:

- `ok`: already true;
- `CHANGE`: changed, or for `plan`, would change;
- `TODO`: a step for a person;
- `FAIL`: false, or could not be read.

## The first runner

1. **Write and validate the inventory** ([installation.md](installation.md),
   [configuration.md](configuration.md)), then run `runner-slice validate`.

2. **See what apply would do.** `sudo runner-slice plan app` lists the account,
   directories, download and units it would create. It changes nothing.

3. **Apply.** `sudo runner-slice apply app` creates:
   - the account and its runtime root;
   - the release, downloaded and verified against its SHA-256;
   - the slice and service units.

   It stops at registration and prints the command for it. The service is not
   started yet.

4. **Register, as a person.** The token lives for an hour, and RunnerSlice
   never handles it:

   ```sh
   export ACTIONS_RUNNER_INPUT_TOKEN="$(gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token)"
   sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner-app -H \
       env -C /var/lib/ci-app/runner HOME=/home/runner-app ./config.sh \
       --url https://github.com/<owner>/<repo> \
       --name <runner-name> --labels <labels> \
       --work /var/lib/ci-app/work --unattended
   unset ACTIONS_RUNNER_INPUT_TOKEN
   sudo chmod 600 /var/lib/ci-app/runner/.runner /var/lib/ci-app/runner/.credentials /var/lib/ci-app/runner/.credentials_rsaparams
   ```

   Copy the exact command `apply` printed. It has your names and labels in it.

   `env -C` runs `config.sh` in its own directory. `config.sh` checks its
   native libraries with `./bin/...` paths before it changes directory, so run
   from anywhere else that check finds no files, prints `ldd: … No such file
   or directory`, and passes without checking anything (actions/runner #945,
   #4460).

   There is no `--replace`. If a runner of that name is already registered to
   the repository, `config.sh` refuses, because that runner may be another
   host's. Find out which it is before re-registering with `--replace`.

   The token travels in the environment, never as an argument. A command line
   is logged by sudo and shown by `ps` to every account, and anyone holding
   the token within its hour can register a runner of their own to the
   repository.

5. **Apply again.** `apply` confirms that the registration names the profile's
   repository, runner and work folder. Then it enables and starts the
   service. A registration for anything else is refused, and the service is
   not started.

6. **Use it** from a workflow in that repository:

   ```yaml
   runs-on: [self-hosted, lab, app]
   ```

7. **Prove it.** Run `sudo runner-slice check app` for the boundary and the
   limits, then `runner-slice status app` for GitHub's view.

## More runners, and pools

- **A runner for another repository** is one new profile. Run `plan`, then
  `apply` for that profile, register it, and `apply` again.
- **Peers adjust automatically.** Every other runner's unit gains a mask for
  the new runtime root, so after adding a profile, run `apply` for the whole
  fleet with the runners idle. The fleet refuses to start while any registered
  runner is busy or its state is unknown, and changes nothing. Run it again
  when they are idle.
- **Pools.** To add a pool member for a repository that already has a runner,
  give the first profile `runner-pool <id>`. Add `<id>-2.conf` with the same
  repository, pool and labels, plus its own id as a label. Then `apply`,
  register and `apply` as above. Workflows select the pool by its label.

## Changing the configuration

`plan` shows the effect before anything happens.

- **A slice limit** changes on `apply` through a systemd reload. No runner is
  restarted.
- **A runner's unit** (masks, sandbox class) changes with the runner idle:
  - the new unit is installed, and the runner is restarted once;
  - if a job is running, the new unit is **not installed**: `apply` reports a
    `TODO` and leaves the runner alone; run `apply` again after the job;
  - if the job state cannot be read, `apply` fails and changes nothing for
    that runner.
- **The release seed** affects only fresh installs. Registered runners update
  themselves, and `check` fails only if one falls below the seed.

## Retiring a runner

`sudo runner-slice retire <id>` takes one safe step per run. Run it again after
each step a person takes.

1. **Busy.** It refuses while a job runs. Drain the runner first, by removing
   its custom labels on GitHub (the command is printed), then wait.
2. **Stop.** It stops and disables the service.
3. **Deregister.** It stops with exit code 10 until a person has deregistered
   the runner (the command is printed). If GitHub is unreachable, delete the
   runner on GitHub and remove the registration files by hand.
4. **Remove.** It checks everything first: the unit is RunnerSlice's, the
   runtime root carries this profile's marker, the account has RunnerSlice's
   shape, and no process runs as the account. Any uid counts: real,
   effective, saved or filesystem. If `/proc` cannot be read, it removes
   nothing. Then it removes, in this order:
   - the account, its home, and its own group;
   - the runtime root, with its marker last;
   - the unit.

   Removal is not atomic. If a step fails, the steps after it are not taken,
   what is left is reported by name, and running `retire` again continues
   from there. Only things RunnerSlice created are removed.

Then delete the profile and apply the remaining runners. Their units drop the
mask for the retired root.

## Recovery

| Symptom | What it means | What to do |
|---|---|---|
| `apply` stopped part-way (power loss, `Ctrl-C`, failed download) | Every step checks the host before it acts. | Run `apply` again. An unpack interrupted part-way is detected, by a missing seed marker, and redone. A registered runner is never re-unpacked. |
| `FAIL ... exists and was not written by RunnerSlice` | A unit of that name belongs to something else. | Rename the profile, or remove the other unit yourself. RunnerSlice will not take it over. |
| `FAIL account ... is not a RunnerSlice system account` | A person's account has the runner's name. | Change `user-prefix` or the profile id. RunnerSlice never adopts or removes it. |
| `TODO ... has a new unit, but a job is running` | A unit change is waiting for a job. | Run `apply` again after the job. |
| `FAIL cannot tell whether ... is running a job` | The runner's cgroup or processes could not be read. | Find out why, for example a stopped service or an unreadable `/proc`. Nothing was restarted. |
| `FAIL the registration does not match the profile` | The runner was registered with another repository, name or work folder. | Deregister it, then register again with the command `apply` prints for an unregistered runner. |
| `check`: `NOT masked in namespace` | The running service does not have a mask its unit declares. Usually it was started before the unit changed. | `apply` with the runner idle restarts it with the current unit. |
| `check`: `differs from the rendering`, `unexpected drop-in` | Someone edited a unit or added a drop-in. | Remove the drop-in, then `apply`. |
| `check`: `runner version ... below the seed` | Self-update is not working. | Re-seed by hand, with the runner idle (`apply` prints how). Registration files survive an unpack. |
| `retire`: `processes of ... are still running` | A job left a process behind, possibly one that only kept the account as its saved uid. | Stop it (`ps -eo pid,ruid,euid,suid,cmd`), then `retire` again. Nothing was removed. |
| `retire`: `cannot tell whether any process runs as ...` | `/proc` could not be read. | Find out why. Nothing was removed. |
| `retire`: `userdel could not remove ...` | The account is still there. | Nothing else was removed. The unit and runtime root still identify the runner. Fix the cause, then `retire` again. |
| `retire`: `could not remove all of ...` | The account is gone; part of the runtime root is not, perhaps a mount below it or an immutable file. | The unit and the root's marker are kept. Fix the cause, then `retire` again; it finishes the root, then the unit. |
| `retire`: `/home/... is still there without its account` | `userdel` removed the account but not its home. | Look at what is in it, then remove it by hand. Until then, `apply` refuses to create the account again. |
| `retire`: `group ... exists without its account` | The account is already gone, so RunnerSlice can no longer prove the group was its own. This is found on a later run, after the group was not removed on the run that removed the account. | If nothing else uses it (`getent group <name>`, `awk -F: '$4 == <gid>' /etc/passwd`), remove it by hand: `groupdel <name>`. |
| `retire` or `apply`: `refusing to remove ...` / `... exists and was not created by RunnerSlice` (runtime root) | The root has no marker, or the marker names another profile or is a symlink. RunnerSlice cannot prove the directory is this runner's, so it never takes it over or removes it. | See "A runtime root without its marker" below. |
| `apply`: `group ... exists without an account of that name` or `/home/... exists without an account` | A leftover of an earlier install, or someone else's. | If it is a leftover and nothing uses it, remove it by hand (`groupdel`, `rm -rf`), then `apply`. |
| `status`: `remote runner is not online` | GitHub does not see the runner. | Look at the service journal: `journalctl -u <service>`. |
| After a reboot | Units are enabled and start with the host. | Run `check`. Then run `status`. |

### A runtime root without its marker

`/var/lib/<prefix>-<id>/.runner-slice-root` is root-owned and names its
profile. Without it, RunnerSlice will not adopt or remove the directory.
That holds even if RunnerSlice created it, for example when someone deleted
the marker or restored the directory from a backup without it. Nothing
recreates the marker automatically. Writing a marker is a claim that the
whole directory is this runner's, and it is a person's decision:

1. Check that the runner is stopped: `systemctl status <service>`.
2. Look at what is in the directory. If any of it is not this runner's, move
   that out first, or rename the profile and leave the directory alone.
3. If the runner was registered, deregister it on GitHub. Its `.credentials`
   are in this directory.
4. Either remove the directory by hand, or restore the marker. To restore
   it, run `printf '%s\n' <id> | sudo tee /var/lib/<prefix>-<id>/.runner-slice-root`,
   then `sudo chown root:root` and `sudo chmod 0644` on the marker. The id
   is the profile's file name without `.conf`.
5. Run `apply` or `retire` again.
