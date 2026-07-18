[Podman](https://github.com/containers/podman) Version Updater (Source Build, apt-managed)
============================================================================================

**Build any Podman release from GitHub for Ubuntu 26.04 and install Podman and its dependencies as an apt-tracked packages.**

* * *

### IMPORTANT WARNINGS: READ THIS FIRST

#### This process replaces a system-level package

The script builds Podman (and its dependencies) from source, packages each as a `.deb`, and installs it via `apt`/`dpkg` — so it *is* a standard package install as far as your system is concerned, but the package itself is self-compiled rather than Canonical-shipped. Breakage, data loss, or unexpected system behavior are still possible.

#### Complete backup is recommended

Before running any of these scripts, you should back up:

*   All container data, volumes, and images.
*   Your entire home directory, or at least `~/.local/share/containers`.
*   Any custom Quadlet unit files.
*   Full system snapshots (Timeshift, LVM, or similar) if possible.

The author takes zero responsibility for data loss, broken containers, or unbootable systems. You assume all risk.

#### Tested only on Ubuntu 26.04

This toolchain was written and validated **exclusively** on:

*   **Ubuntu 26.04 (Resolute)** running **Podman 5.7.0** (apt-managed)

This script will only run on Ubuntu 26.04 and 25.10. Other versions and OSes may work, but you would have to remove the `$ID` and `$VERSION-ID` check (at your own risk) to get it to run. You may need to tweak dependencies in the script to get it to run on earlier versions of Ubuntu.

#### Dependency version check is YOUR job

The updater script installs build dependencies via `apt`, but it does **not** verify whether those packages meet the minimum versions required by the Podman release you are building. Always read the [official build instructions](https://github.com/containers/podman/blob/main/install.md) for your target tag and ensure your system's libraries are new enough.

* * *

How It Works
------------

*   **Every install is via `.deb`.** The script builds each component from source, stages the build into a throwaway directory, packages it with [`fpm`](https://github.com/jordansissel/fpm), and installs it with `apt-get install ./<component>.deb`. Nothing is kept afterward — the staging directory and the built `.deb` are deleted immediately. `dpkg`'s own database is what tracks the install, exactly as if a real apt repo had shipped that version.
*   **Dependencies always build to the newest known-good version**, regardless of which Podman version you're installing. Netavark, Aardvark-dns, conmon, fuse-overlayfs, and containers-common are always brought current first.
*   Give the script a version string, not a URL. See [Usage](#usage) below.
*   The script backs up your running containers, stops services gracefully, verifies the new binary, and restores everything automatically.
*   **Every component is `apt-mark hold`-ed after install**, so a future `apt upgrade` can't silently clobber your custom build if Ubuntu's repo ever ships a conflicting version.
*   **If anything fails, nothing on the real filesystem has been touched yet** — each component only replaces the previous install via `apt-get install` after its `.deb` builds successfully. A failed build leaves whatever was previously installed completely intact.

* * *

Usage
-----

### Get the script

Clone the repository:

    git clone https://github.com/upmcplanetracker/podman-version-updater.git
    cd podman-version-updater
    chmod +x podman-version-updater.sh

Or download just the required file:

    wget https://raw.githubusercontent.com/upmcplanetracker/podman-version-updater/main/podman-version-updater.sh
    chmod +x podman-version-updater.sh

### Upgrade to any Podman version > 5.7.0

Run the script with a version string — not a URL. Accepted formats:

| Input | Resolves to |
|---|---|
| `v6.0.1` | `v6.0.1` |
| `6.0.1` | `v6.0.1` |
| `601` (exactly 3 digits) | `v6.0.1` |
| `latest` | newest non-prerelease tag on GitHub |
| `v6.0.1-rc1` | `v6.0.1-rc1` (prerelease suffixes pass through) |
| `6.0.1-beta` | `v6.0.1-beta` |

Compact digit input only works for exactly 3 digits — anything longer or ambiguous (`6010`, `61`) is rejected; use dotted notation instead. Every version is checked against `containers/podman`'s real GitHub tags before anything is built, so a typo fails fast instead of cloning a branch that doesn't exist.

Examples:

#### Upgrade to Podman 5.8.5

    ./podman-version-updater.sh 5.8.5

#### Upgrade to Podman 6.0.1

    ./podman-version-updater.sh 601

#### Upgrade to whatever's newest

    ./podman-version-updater.sh latest

The script automatically:

*   Installs build tools (`cargo`, `protoc`, `git`, `fpm` — installed on first run if missing).
*   Builds **Netavark** and **Aardvark-dns**, packages each as a `.deb`, and installs via apt. A postinst hook symlinks both into `/usr/lib/podman/` — Podman hardcodes this path and ignores `$PATH` when looking for network binaries, so this happens automatically on every install, not as a manual follow-up step.
*   Downloads **crun**'s prebuilt release binary, wraps it in a `.deb`, installs via apt.
*   Builds **conmon**, packages, installs via apt.
*   Builds **fuse-overlayfs** and installs it *without* apt. This is a fallback storage driver only — it stays completely inactive if native rootless overlay is in use (the default on modern kernels), and is only invoked if Podman needs it.
*   Packages the rootless **containers-common** configuration files (`storage.conf`, `containers.conf`, `registries.conf`, seccomp profiles) as a config-only `.deb` and installs it into `/etc/containers` and `/usr/share/containers`.
*   Then builds and installs Podman itself the same way, with a postinst hook that masks the system-level services (see below).

Exact target versions for each dependency are defined as variables at the top of `podman-version-updater.sh` — edit them there when new upstream releases come out. The script skips rebuilding any dependency already installed at the target version (checked via `dpkg-query`, not by probing `$PATH`).

The entire process is handled in one run, ensuring the network stack and Podman are always synchronised.

* * *

### Handling Custom Graphroots

If you have a custom storage graphroot defined in `/etc/containers/storage.conf`, the script automatically creates a backup at `/tmp/podman-config-backup-<TIMESTAMP>` before the containers-common package overwrites it.

1.  Run the upgrade script with your target version.
2.  After the upgrade, verify your current graphroot: `podman info | grep graphRoot`.
3.  If it has reverted to the default, stop all containers, copy your original `storage.conf` from the backup directory back to `/etc/containers/storage.conf`, and restart the Podman services.

This keeps the script clean and ensures that users with advanced, non-standard storage setups don't lose their data during an upgrade.

* * *

System-Level Podman Services and Rootless Container Ownership
-------------------------------------------------------------

When Podman is installed, its package deploys several systemd system-level unit files:

*   `podman.service` / `podman.socket`
*   `podman-auto-update.service` / `podman-auto-update.timer`
*   `podman-clean-transient.service`
*   `podman-restart.service`

These units run as **root** and are designed for system-wide (rootful) Podman deployments. If you run rootless Podman with Quadlet, they are not only unnecessary — they are dangerous. Specifically, `podman-clean-transient.service` can reset ownership of container storage paths to `root:root` on boot, causing all rootless Quadlet services to fail to start.

### Why `disable` alone isn't enough

`systemctl disable` removes the symlinks that cause a unit to start automatically, but systemd **preset processing** (triggered by package installs or `daemon-reload` in some configurations) can re-enable units whose preset state is `enabled`. You can verify this with:

    systemctl list-unit-files | grep podman
    # Look for units showing: disabled    enabled
    # The second column is the preset — "enabled" means it CAN be re-enabled.

`systemctl mask` replaces the unit file with a symlink to `/dev/null`, making it impossible for any mechanism to start the unit until you explicitly unmask it.

### What this script does

The **podman package's own postinst script** automatically **masks** all system-level Podman units on every install — this now lives inside the `.deb` itself (not a manual step run by the shell script), so it fires correctly even on a bare `dpkg -i` reinstall. A matching **prerm** unmasks them if the package is ever removed, so a later `apt install podman` from the stock repo doesn't inherit masked services.

If you ever hit container ownership errors after a reboot, verify unit state:

    systemctl list-unit-files | grep podman
    # All entries should show: masked    enabled

If any show `disabled` instead of `masked`, re-run the mask manually:

    sudo systemctl mask \
        podman.service podman.socket \
        podman-auto-update.service podman-auto-update.timer \
        podman-clean-transient.service podman-restart.service

### If you need rootful system-level Podman

If you intentionally run system-level Podman containers alongside rootless ones, unmask only the specific units you need and ensure they do not touch your rootless user's storage paths.

* * *

Rollback
--------

There are two distinct rollback modes now, because there's no kept `.deb` file to fall back to — nothing is retained on disk by design.

### Rebuild and reinstall an older version

    ./podman-version-updater.sh --rollback 5.8.5

This re-runs the normal build → package → apt-install pipeline targeting the older version you specify. `apt install ./podman-<version>.deb` overwrites the currently installed package — dpkg treats this as a plain reinstall/downgrade of the same package name, no different from installing any other version. This is slower than restoring a cached file would be, but there's nothing to store or clean up.

### Revert entirely to Ubuntu's stock packages

    ./podman-version-updater.sh --rollback-to-stock

This releases the `apt-mark hold` on every custom-built component (`podman`, `conmon`, `crun`, `netavark`, `aardvark-dns`, `fuse-overlayfs`, `containers-common`) and reinstalls whatever version Ubuntu's own repo currently provides via `apt install --reinstall`. This is the fast path with no rebuild and no waiting. It's the equivalent of the old `--rollback` behavior plus the manual cleanup commands that used to be a separate step.

Because both modes go through normal `apt`/`dpkg` operations, `dpkg -l | grep -E 'podman|conmon|crun|netavark|aardvark|fuse-overlayfs|containers-common'` always reflects exactly what's installed and there's no more checking `/usr/local/bin` versus `/usr/bin` to figure out which version is actually active.

* * *

After a successful upgrade
---------------------------

    podman --version
    podman ps -a
    systemctl --user status podman.socket

* * *

Verify your containers and networks
-----------------------------------

The script restarts all containers that were previously running, but you should always confirm:

    podman ps -a

If any containers are stopped, start them manually:

    podman start --all

For Quadlet users, check that the systemd units are active:

    systemctl --user status $(basename -s .container ~/.config/containers/systemd/*.container)
    # or for rootful Quadlets
    sudo systemctl status $(basename -s .container /etc/containers/systemd/*.container)

* * *

Managing Installed Podman Versions
-----------------------------------

Unlike the old `/usr/local`-shadow approach, there is only ever **one installed Podman** at a time — the custom-built package *is* what `apt`/`dpkg` considers installed, at the standard `/usr/bin/podman` path. There's no fallback binary sitting alongside it, and no `$PATH` precedence to think about.

*   **Check what's installed and held:**

        dpkg -l | grep -E 'podman|conmon|crun|netavark|aardvark|fuse-overlayfs|containers-common'
        apt-mark showhold

*   **Go back to an older custom build:** `--rollback <version>` (rebuilds and reinstalls).
*   **Go back to Ubuntu's stock packages entirely:** `--rollback-to-stock` (drops the holds, reinstalls from the repo — instant, no rebuild).

Because holds are applied automatically after every install, a plain `sudo apt upgrade` will never silently overwrite a custom build — you always have to explicitly unhold or run one of the two rollback modes above.

* * *

Cleanup
-------

There's much less to clean up now, since builds and packages are deleted automatically as part of every install:

*   `~/podman-state-backup.txt` – container state snapshot, removed automatically on a successful run.
*   `/tmp/podman-build.*`, `/tmp/<component>-pkg-*` – build/staging directories, removed automatically on success (and cleared on reboot regardless).
*   `/tmp/container-libs-common` – temporary clone of the containers-common config repo, removed automatically after staging.
*   `/tmp/podman-config-backup-<TIMESTAMP>` – backup of your original `/etc/containers` config, created before every upgrade. Review before deleting if you have custom storage paths as this one is **not** auto-removed.

* * *

**Remember: you are still replacing core system packages with self-compiled versions. Proceed with caution, full backups, and a thorough understanding of your own environment — the apt/dpkg integration makes it easier to track and roll back, but it doesn't make the underlying operation any less consequential.**
