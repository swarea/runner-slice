# Installation

> **Status: pre-release.** These steps follow what the code does and are
> exercised by drills against a fixture host. They have not yet been carried
> out on a real host. That is the next verification stage
> ([verification.md](verification.md)). Until it is done, use a disposable
> machine.

## Requirements

What preflight refuses to work without:

- **Ubuntu**, with systemd 249 or later.
- **The cgroup v2 unified hierarchy**, with the `cpu`, `memory` and `pids`
  controllers available.
- **x86_64 or aarch64**, matching the `runner-platform` of the release seed.
- **Commands:** `bash` 4 or later, `python3`, `curl`, `tar`, `sha256sum`,
  `getent`, `runuser`, `useradd`, `install`, `systemctl` and `nproc`.
- **For `runner-slice status`:** the GitHub CLI (`gh`), authenticated as an
  ordinary user with access to each repository's runners.

Which combinations have actually been verified is recorded in
[compatibility.md](compatibility.md).

## Get the release archive

There is no published release yet. Build the archive from a commit you have
reviewed:

```sh
git clone https://github.com/swarea/runner-slice.git
cd runner-slice
git checkout <commit>
bash tests/run.sh                                  # needs shellcheck
bash scripts/release.sh --out ../dist --snapshot   # -dev versions need --snapshot
```

The build is reproducible: the same commit gives the same bytes and the same
`runner-slice-<version>.tar.gz.sha256`. When releases are published, verify the
download against the published checksum:

```sh
sha256sum -c runner-slice-<version>.tar.gz.sha256
```

## Install

As root, unpack the archive so that root owns every file. Then link the
command:

```sh
tar -xzf runner-slice-<version>.tar.gz -C /opt --no-same-owner
ln -s /opt/runner-slice-<version>/bin/runner-slice /usr/local/bin/runner-slice
runner-slice version
```

The unpacked tree verifies itself; this needs `shellcheck`:

```sh
(cd /opt/runner-slice-<version> && sudo -u nobody bash tests/run.sh)
```

The tool and its configuration must be writable by root alone. Preflight
refuses to run as root from a tree, or with a configuration, that another
account could change.

## Write the inventory

```sh
install -d -o root -g root -m 0755 /etc/runner-slice /etc/runner-slice/profiles
cp /opt/runner-slice-<version>/examples/basic/fabric.conf /etc/runner-slice/
cp /opt/runner-slice-<version>/examples/basic/runner-release.conf /etc/runner-slice/
```

Edit both files for your host ([configuration.md](configuration.md)). In
particular, set:

- the slice limits for what this host can spare;
- the `common-mask` and `protected-path` entries for your other services;
- the release seed for your architecture.

Then write one profile per runner, and check everything offline:

```sh
runner-slice validate
```

The first runner is walked through in [operations.md](operations.md).

## Upgrade RunnerSlice

1. Unpack the new version beside the old one.
2. Run `runner-slice plan` with the new version's command, and read what it
   would change.
3. Move the symlink.
4. Run `runner-slice apply` while the runners are idle. Unit changes wait for
   running jobs.

To roll back, move the symlink back and apply again.

## Remove RunnerSlice

1. Retire every runner, deregistering each from GitHub ([operations.md](operations.md)).
2. Remove `/usr/local/bin/runner-slice` and `/opt/runner-slice-<version>`.
3. Remove `/etc/runner-slice` and the slice unit in `/etc/systemd/system`.
4. Run `systemctl daemon-reload`.
