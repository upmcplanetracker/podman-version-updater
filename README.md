[Podman](https://github.com/podman-container-tools/podman) Version Updater (Source Build)
=========================================================================================

**Build and install any Podman release from GitHub for Ubuntu 26.04 without touching your apt‑managed binary.**

* * *

### IMPORTANT WARNINGS: READ THIS FIRST

#### This process replaces a system‑level binary

Replacing a core container runtime by compiling from source is a **high‑risk operation**. The script installs a self‑compiled Podman into `/usr/local`, which overrides the system package. This is not a standard `apt` upgrade and carries potential for breakage, data loss, or unexpected system behaviour.

#### Complete backup is mandatory

Before running any of these scripts, you **must** back up:

*   All container data, volumes, and images.
*   Your entire home directory, or at least `~/.local/share/containers`.
*   Any custom Quadlet unit files.
*   Full system snapshots (Timeshift, LVM, or similar) if possible.

The author takes **zero responsibility** for data loss, broken containers, or unbootable systems. You assume **all risk**.

#### Tested only on Ubuntu 26.04

This toolchain was written and validated **exclusively** on:

*   **Ubuntu 26.04 (Resolute)** running **Podman 5.7.0** (apt‑managed)

If you are using a different OS, a different base version, or a different target version, verify that **all** build and runtime dependencies are compatible.

#### Dependency version check is YOUR job

The updater script installs build dependencies via `apt`, but it does **not** verify whether those packages meet the minimum versions required by the Podman release you are building. Always read the [official build instructions](https://github.com/podman-container-tools/podman/blob/main/install.md) for your target tag and ensure your system’s libraries are new enough.

* * *

How It Works
------------

*   **For any Podman version** – run the single updater script with the desired GitHub release tag. The script clones the source, builds, installs, migrates the database, and restarts your containers.
*   **For Podman ≥ 6.x** – the script automatically builds and installs **Netavark 2.0.0**, **Aardvark‑dns 2.0.0**, and the required rootless container configuration files **before** building Podman. No separate preparation step is needed.
*   The script backs up your running containers, stops services gracefully, verifies the new binary, and restores everything automatically.
*   **If anything fails, the updater removes any partially installed files and leaves your original Podman untouched.**
*   The rollback function (`--rollback`) removes only the Podman binary and libraries placed by the updater. The dependency binaries (Netavark / Aardvark) installed for v6 are **not** removed automatically—see the Rollback section for manual cleanup.

* * *

Usage
-----

### 0\. Make sure Podman is already installed

**Prerequisite:** Podman must already be installed on your system before running this script. If not, install the Ubuntu repo version via `sudo apt update && sudo apt install podman`.

### 1\. Get the script

Clone the repository:

    git clone https://github.com/upmcplanetracker/podman-version-updater.git
    cd podman-version-updater
    chmod +x podman-version-updater.sh

Or download just the required file:

    wget https://raw.githubusercontent.com/upmcplanetracker/podman-version-updater/main/podman-version-updater.sh
    chmod +x podman-version-updater.sh

### Upgrading to any Podman version

Run the script with the desired release tag URL. Examples:

#### Upgrade to Podman 5.8.5

    ./podman-version-updater.sh https://github.com/podman-container-tools/podman/releases/tag/v5.8.5

#### Upgrade to Podman 6.x (e.g., v6.0.0)

    ./podman-version-updater.sh https://github.com/podman-container-tools/podman/releases/tag/v6.0.0

**No separate preparation step is required.** The script automatically:

*   Installs build tools (`cargo`, `protoc`, `git`).
*   Clones, builds, and installs **Netavark 2.0.0** → `/usr/local/bin/netavark`
*   Clones, builds, and installs **Aardvark‑dns 2.0.0** → `/usr/local/bin/aardvark-dns`
*   Copies **Netavark 2.0.0** and **Aardvark‑dns 2.0.0** to `/usr/lib/podman/` — Podman hardcodes this path and ignores `$PATH` when looking for network binaries.
*   Creates rootless container configuration files in `/etc/containers` (storage.conf, containers.conf).
*   Then proceeds to build and install Podman itself.

The entire process is handled in one run, ensuring the network stack and Podman are always synchronised.

* * *

### Handling Custom Graphroots

If you have a custom storage graphroot defined in `/etc/containers/storage.conf`, the script automatically creates a backup at `/tmp/podman-config-backup-<TIMESTAMP>` before updating the configuration for v6.

1.  Run the upgrade script with the v6 tag.
2.  After the upgrade, verify your current graphroot: `podman info | grep graphRoot`.
3.  If it has reverted to the default, stop all containers, copy your original `storage.conf` from the backup directory back to `/etc/containers/storage.conf`, and restart the Podman services.

This keeps the script clean and ensures that users with advanced, non‑standard storage setups don't lose their data during the v6 transition.

* * *

System-Level Podman Services and Rootless Container Ownership
-------------------------------------------------------------

When Podman is installed or upgraded from source via `make install`, it deploys several systemd system‑level unit files:

*   `podman.service` / `podman.socket`
*   `podman-auto-update.service` / `podman-auto-update.timer`
*   `podman-clean-transient.service`
*   `podman-restart.service`

These units run as **root** and are designed for system‑wide (rootful) Podman deployments. If you run rootless Podman with Quadlet, they are not only unnecessary — they are dangerous. Specifically, `podman-clean-transient.service` can reset ownership of container storage paths to `root:root` on boot, causing all rootless Quadlet services to fail to start.

### Why `disable` alone isn't enough

`systemctl disable` removes the symlinks that cause a unit to start automatically, but systemd **preset processing** (triggered by package installs or `daemon-reload` in some configurations) can re‑enable units whose preset state is `enabled`. You can verify this with:

    systemctl list-unit-files | grep podman
    # Look for units showing: disabled    enabled
    # The second column is the preset — "enabled" means it CAN be re-enabled.
    

`systemctl mask` replaces the unit file with a symlink to `/dev/null`, making it impossible for any mechanism to start the unit until you explicitly unmask it.

### What this script does

`podman-version-updater.sh` automatically **masks** all system‑level Podman units after every install. If you ever hit container ownership errors after a reboot, verify their state:

    systemctl list-unit-files | grep podman
    # All entries should show: masked    enabled
    

If any show `disabled` instead of `masked`, re‑run the mask manually:

    sudo systemctl mask \
        podman.service podman.socket \
        podman-auto-update.service podman-auto-update.timer \
        podman-clean-transient.service podman-restart.service
    

### If you need rootful system‑level Podman

If you intentionally run system‑level Podman containers alongside rootless ones, unmask only the specific units you need and ensure they do not touch your rootless user's storage paths.

* * *

Rollback to the original apt‑managed Podman
-------------------------------------------

    ./podman-version-updater.sh --rollback

This stops any Podman services, removes the compiled Podman files from `/usr/local`, and restores the system binary from `/usr/bin/podman`. It is safe even if no local version is installed.

**However, the rollback does NOT remove the custom Netavark / Aardvark‑dns binaries that may have been installed.** Those remain in `/usr/local/bin` and `/usr/lib/podman/`. If you want to completely revert to the stock Ubuntu‑shipped network stack, run these additional commands after the rollback:

    # Remove the custom binaries
    sudo rm -f /usr/local/bin/netavark /usr/local/bin/aardvark-dns
    
    # Reinstall the original APT packages — this restores the 1.16.x versions
    # to /usr/lib/podman/ (where Podman actually looks) and /usr/bin/
    sudo apt install --reinstall netavark aardvark-dns

After this, `netavark --version` and `aardvark-dns --version` will show the original 1.16.x versions, and Podman will use the restored binaries in `/usr/lib/podman/`.

You will need to run `hash -r` from the terminal after the rollback is complete in order for the original version of Podman to be found.

* * *

After a successful upgrade: clear your shell’s command hash
-----------------------------------------------------------

    hash -r          # in the same terminal
    # or simply open a new terminal window

Then verify:

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
----------------------------------

After the updater runs, you may have two Podman versions:

*   **Source‑built** (e.g., 5.8.5 or 6.0.0) at `/usr/local/bin/podman`
*   **APT‑managed** (e.g., 5.7.0) at `/usr/bin/podman`

The new version is used because `/usr/local/bin` comes first in `$PATH`.

*   **Keep both (recommended):** The original binary stays as a fallback; rollback is instant.
*   **Remove the APT version:**
    
        sudo apt-mark manual conmon crun netavark uidmap catatonit
        sudo apt purge podman
    
    After this, rollback will **not** work because there is no fallback binary.
*   **Revert completely:** Run `--rollback`, then remove any custom network binaries as described above.

* * *

Cleanup
-------

The scripts create temporary files that can be safely deleted after a successful upgrade:

*   `~/podman-state-backup.txt` – container state snapshot.
*   `/tmp/podman-build.*` – build directories (cleared automatically on reboot).
*   `/tmp/common-0.68.0` – temporary clone of config files (if cloned).
*   `/tmp/podman-config-backup-<TIMESTAMP>` – backup of your original `/etc/containers` config (_v6 upgrades only_). Review before deleting if you have custom storage paths.

* * *

**Remember: you are modifying system binaries. Proceed with caution, full backups, and a thorough understanding of your own environment.**
