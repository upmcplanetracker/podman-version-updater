Podman Version Updater (Source Build)
=====================================

**Build and install any Podman release from GitHub without touching your apt‑managed binary.**

* * *

⚠️ IMPORTANT WARNINGS: READ THIS FIRST ⚠️
-----------------------------------------

### 🛑 This process replaces a system‑level binary

Replacing a core container runtime by compiling from source is a high risk operation. It worked flawlessly on the author’s machine, but that does not guarantee it will work on yours. The script installs a self compiled Podman into `/usr/local`, which overrides the system package. This is not a standard `apt` upgrade and carries potential for breakage, data loss, or unexpected system behaviour.

### 📦 Complete backup is mandatory

Before running this script, you **must** back up:

*   All container data, volumes, and images.
*   Your entire home directory, or at least `~/.local/share/containers`.
*   Any custom Quadlet unit files.
*   Full system snapshots (using Timeshift, LVM, or similar) if possible.

The author takes **zero responsibility** for data loss, broken containers, or unbootable systems. You assume **all risk**.

### 🧪 Tested only on Ubuntu 26.04

This script was written and validated **exclusively** on:

*   **Ubuntu 26.04**
*   **Podman 5.7.0** (apt‑managed) upgrading to **v5.8.3**
*   **Podman 5.8.3** upgrading to **v6.0.0** (with the separate dependency preparation script)

**If you are using a different OS, a different Podman base version, or a different target version, you must verify that ALL build and runtime dependencies are new enough.** Failing to do so will likely cause a build failure or a broken runtime, and could leave your system in an inconsistent state.

### 🧩 Dependency version check is YOUR job

The updater script installs build dependencies using the current `apt` packages available on your system. It does not check whether those libraries meet the minimum version required by the Podman version you want to build. Before proceeding:

*   Read the [official Podman build instructions](https://github.com/containers/podman/blob/main/install.md) for the tag you are targeting.
*   Check the required versions of `go`, `gpgme`, `systemd`, `conmon`, etc.
*   If the required versions are newer than what your distribution ships, you must upgrade those manually. The script will not do it for you.

* * *

📋 How It Works
---------------

1.  **Upgrades to 5.8.3 and earlier** – Run the main updater script directly with the desired tag URL. It will handle everything in one step.
2.  **Upgrades to 6.0.0 and later** – You must first run the `prepare-for-podman6.sh` script to build and install Netavark 2.0.0, Aardvark-dns 2.0.0, and the required containers‑common configuration files. Then run the main updater script as usual.
3.  For upgrades, the script verifies the target version is newer than your current one, then backs up your running containers and records whether the Podman socket is active.
4.  It installs all required build dependencies via `apt`.
5.  It clones the repository, checks out the tag, and compiles Podman.
6.  It safely stops all containers, then stops `podman.service` and `podman.socket` (never your login session).
7.  It installs the new binary into `/usr/local`; the original `/usr/bin/podman` remains untouched.
8.  It runs `podman system migrate` (upgrades only) and verifies the new version.
9.  It restarts the Podman socket and waits for it to be listening, then restarts every container that was previously running. A final message reminds you to verify everything.
10. **If anything fails during the build, install, or verification, the script automatically cleans up any partially installed files, leaving your original Podman fully working.**

* * *

🚀 Usage
--------

### Get the scripts

You can either clone this repository or download just the script files:

#### Option A: Clone this repository

    git clone https://github.com/upmcplanetracker/podman-version-updater.git
    cd podman-version-updater

#### Option B: Download just the scripts

    wget https://raw.githubusercontent.com/upmcplanetracker/podman-version-updater/main/podman-version-updater.sh
    wget https://raw.githubusercontent.com/upmcplanetracker/podman-version-updater/main/prepare-for-podman6.sh
    # or
    curl -O https://raw.githubusercontent.com/upmcplanetracker/podman-version-updater/main/podman-version-updater.sh
    curl -O https://raw.githubusercontent.com/upmcplanetracker/podman-version-updater/main/prepare-for-podman6.sh

### Make them executable

    chmod +x podman-version-updater.sh prepare-for-podman6.sh

---

### 🔹 Upgrading to Podman 5.8.3 (or any version < 6.0.0)

    ./podman-version-updater.sh https://github.com/containers/podman/releases/tag/v5.8.3

For a future release, just change the URL.

---

### 🔸 Upgrading to Podman 6.0.0 (or any version ≥ 6.0.0)

**First, prepare the required runtime dependencies** (Netavark 2.0.0, Aardvark-dns 2.0.0, and rootless config files):

    ./prepare-for-podman6.sh

This script is idempotent – you can run it multiple times safely. It installs the new binaries into `/usr/local/bin` and creates `/etc/containers/containers.conf` and `storage.conf` for rootless operation.

**Then, run the main updater** with the v6.0.0 tag:

    ./podman-version-updater.sh https://github.com/containers/podman/releases/tag/v6.0.0

(If you are building from a fork, replace the URL with your fork’s release tag.)

**Optional one‑shot mode:** If you provide the path to the updater script and the tag URL, `prepare-for-podman6.sh` will automatically run the upgrade after preparing dependencies:

    ./prepare-for-podman6.sh ./podman-version-updater.sh https://github.com/containers/podman/releases/tag/v6.0.0

---

### Fresh install (no Podman installed yet)

    ./podman-version-updater.sh --fresh-install https://github.com/containers/podman/releases/tag/v5.8.3

This will install all necessary runtime dependencies, then build and install Podman from source. For a fresh install of v6.0.0, run the `prepare-for-podman6.sh` script first.

### Rollback to the original apt‑managed Podman

    ./podman-version-updater.sh --rollback

Stops any Podman services, removes the compiled files from `/usr/local`, and restores the system binary. It is safe to run even if no locally built version is present.

### After a successful update or fresh install: clear your shell’s command hash

Your terminal may still show the old version number because your shell cached the old binary’s location. Run one of these:

    hash -r          # in the same terminal
    # or simply open a new terminal window

### After the upgrade: check your containers and sockets

The script restarts all containers that were running before the upgrade, but you should still verify:

    podman ps -a

If any containers are stopped, start them with:

    podman start --all

Also ensure the Podman socket is active (important for API‑based tools like Homepage or Portainer):

    systemctl --user status podman.socket

If it is not running, start it with:

    systemctl --user start podman.socket

Some containers connect to the socket only once at startup; restart them manually if they fail after the upgrade.

If you rely on a Docker‑compatible socket (`/var/run/docker.sock`), check that as well:

    systemctl --user status podman-docker.socket   # if applicable

####  For Quadlet Users

If your containers are managed by Quadlet (systemd unit files inside `~/.config/containers/systemd/`), the script now restarts them automatically via their systemd units. If you still see stopped containers, manually run:

    systemctl --user start $(ls ~/.config/containers/systemd/*.container | xargs -n1 basename | sed 's/\.container$//')

For rootful Quadlet containers (`/etc/containers/systemd/`), the script does not restart them automatically. After an upgrade, restart them with:

    sudo systemctl restart $(ls /etc/containers/systemd/*.container | xargs -n1 basename | sed 's/\.container$//')

Then verify with `sudo podman ps`.

* * *

🔄 Managing Installed Podman Versions
-------------------------------------

After running the updater, your system may have **two** Podman versions:

*   **Source‑built** (e.g., 5.8.3 or 6.0.0) at `/usr/local/bin/podman`.
*   **APT‑managed** (e.g., 5.7.0) at `/usr/bin/podman`.

The new version is used automatically because `/usr/local/bin` comes first in your `$PATH`. You can safely keep both: the original binary is untouched and ready as a fallback.

### ✅ Option 1: Keep both (recommended)

Do nothing extra. This gives you the latest features from your compiled version, instant rollback with `--rollback`, and zero risk of accidentally removing critical runtime dependencies.

### 🗑️ Option 2: Use only the source‑built version (remove the APT package)

**Warning:** After doing this, `--rollback` will **not** work because there will be no fallback binary.

1.  Ensure the source‑built version is working correctly.
2.  **Mark the runtime dependencies as manually installed** so APT will not auto‑remove them:
    
        sudo apt-mark manual conmon crun netavark uidmap catatonit
    
3.  Remove the APT package:
    
        sudo apt purge podman
    

After this, only `/usr/local/bin/podman` remains. Your containers and images are not affected.

### 🔙 Option 3: Revert completely to the APT version

    ./podman-version-updater.sh --rollback

Stops services, removes compiled files, and restores the original system services. No further cleanup is needed.

### ⚠️ What happens if you purge the APT version and then try to roll back?

**The rollback will fail.** The script will remove the only remaining Podman binary, leaving you with no Podman at all. You would need to reinstall the APT package (`sudo apt install podman`) to recover.

* * *

🧹 Cleanup
----------

The scripts create temporary files during the upgrade:

*   `~/podman-state-backup.txt`: full list of containers with states before the upgrade.
*   `prepare-for-podman6.sh` clones and builds inside `/tmp`, which is cleared automatically on reboot.

You can delete the state backup after a successful update or keep it for reference.

* * *

**Remember: you are modifying system binaries. Proceed with caution, full backups, and a thorough understanding of your own environment.**
