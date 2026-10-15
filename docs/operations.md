# Operations

> **Status: pre-release.** The commands and outputs below are what the code
> does under its drills. They have not yet been observed on a real host
> ([verification.md](verification.md)).

The command forms used throughout:

```text
runnerslice [--config DIR] validate                 offline, any user
runnerslice [--config DIR] plan    [PROFILE]        as root; changes nothing
runnerslice [--config DIR] apply   [PROFILE]        as root
runnerslice [--config DIR] retire  PROFILE [--check] as root
runnerslice [--config DIR] check   [PROFILE]        as root; changes nothing
runnerslice [--config DIR] status  [PROFILE]        as an ordinary user with gh
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
   [configuration.md](configuration.md)), then run `runnerslice validate`.

2. **See what apply would do.** `sudo runnerslice plan app` lists the account,
   directories, download and units it would create. It changes nothing.

3. **Apply.** `sudo runnerslice apply app` creates:
   - the account and its runtime root;
   - the release, downloaded and verified against its SHA-256;
   - the slice and service units.

   It stops at registration and prints the command for it. The service is not
   started yet.

4. **Register, as a person.** The token lives for an hour, and RunnerSlice
   never handles it:

   ```sh
   TOKEN=$(gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token)
   sudo -u runner-app -H env HOME=/home/runner-app /var/lib/ci-app/runner/config.sh \
       --url https://github.com/<owner>/<repo> --token "$TOKEN" \
       --name <runner-name> --labels <labels> \
       --work /var/lib/ci-app/work --unattended --replace
   sudo chmod 600 /var/lib/ci-app/runner/.runner /var/lib/ci-app/runner/.credentials /var/lib/ci-app/runner/.credentials_rsaparams
   unset TOKEN
   ```

   Copy the exact command `apply` printed. It has your names and labels in it.

5. **Apply again.** `apply` confirms that the registration names the profile's
   repository, runner and work folder. Then it enables and starts the
   service. A registration for anything else is refused, and the service is
   not started.

6. **Use it** from a workflow in that repository:

   ```yaml
   runs-on: [self-hosted, lab, app]
   ```

7. **Prove it.** Run `sudo runnerslice check app` for the boundary and the
   limits, then `runnerslice status app` for GitHub's view.

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

`sudo runnerslice retire <id>` takes one safe step per run. Run it again after
each step a person takes.

1. **Busy.** It refuses while a job runs. Drain the runner first, by removing
   its custom labels on GitHub (the command is printed), then wait.
2. **Stop.** It stops and disables the service.
3. **Deregister.** It stops with exit code 10 until a person has deregistered
   the runner (the command is printed). If GitHub is unreachable, delete the
   runner on GitHub and remove the registration files by hand.
4. **Remove.** It removes the unit, the runtime root and the account. Only
   things RunnerSlice created are removed.

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
| `status`: `remote runner is not online` | GitHub does not see the runner. | Look at the service journal: `journalctl -u <service>`. |
| After a reboot | Units are enabled and start with the host. | Run `check`. Then run `status`. |
